<!--
SPDX-FileCopyrightText: Copyright (c) 2026 Jason Perlow. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# Agent stack invariants

This document declares the security and operational invariants that the
nclawzero agent stack — `zeroclaw`, `openclaw`, `hermes` — must satisfy at
build time, install time, and runtime. The `ncz agent install` flow checks the
mechanically-verifiable invariants before laydown and refuses to deploy a
bundle that violates them.

The invariants are scoped per layer:

- **§1 Image** — properties of the OCI image, regardless of how it's deployed
- **§2 Sandbox** — properties enforced by the OpenShell policy layer
  (Naked-deployed agents satisfy a strict subset)
- **§3 Install flow** — properties of the `ncz agent install` /
  `ncz agent enable` operations performed by the operator

Each invariant has:

- **Statement** — the property in declarative form
- **Why** — the threat or operational concern it addresses
- **Check** — how compliance is verified (`programmatic` if `ncz agent install`
  enforces it pre-laydown; `manual` if it requires human review)

---

## §1 Image invariants

These apply to every OCI image in the agent catalog (`nclawzero-stack:naked`,
`nclawzero-stack:openshell`, and any future variants). They are properties of
the bake, not of the deploy.

### I-1: Agent processes run as a non-root user after entrypoint drops privileges

- **Why:** Container escape via a kernel CVE or runtime bug must not yield root
  on the host. `sandbox` user (UID >= 1000, no shell, no sudo) is the canonical
  identity.
- **Check:** `programmatic` — `ncz agent install` runs `podman inspect
  --format '{{.Config.User}}' <image>` against each catalog image and refuses
  any entry that returns empty, `0`, `root`, or a UID < 1000.

### I-2: No CAP_SYS_ADMIN, CAP_NET_ADMIN, CAP_SYS_PTRACE in the image's declared capabilities

- **Why:** These caps grant kernel-level operations that defeat sandboxing.
  Agents need none of them; image bakes that grant them are bugs, not features.
- **Check:** `programmatic` — `ncz agent install` parses the image manifest's
  `Config.Cmd` / `Config.Entrypoint` and the quadlet's `AddCapability=` lines;
  refuses any image whose effective cap set includes the forbidden trio.

### I-3: No SETUID / SETGID binaries inside the image rootfs

- **Why:** A SETUID binary is a local privilege escalation primitive once an
  attacker is inside the container. Modern container distros ship without
  SETUID by default; image bakes that re-introduce it (commonly via
  `apt-get install` of legacy tooling) are regressions.
- **Check:** `manual` for V1.0 (run `find / -perm /6000 -type f` inside the
  image during build); `programmatic` for V1.1 (move into `ncz agent install`
  using podman + find via exec).

### I-4: Image contains no agent secrets, no API keys, no certificates beyond CA bundles

- **Why:** OCI images are routinely shared, cached, archived. A secret baked
  in is a secret published. Agent-specific credentials enter via
  `EnvironmentFile=/etc/nclawzero/agent-env` at runtime, never via image
  layers.
- **Check:** `manual` for V1.0 (review of Dockerfile + base layers — no
  COPY of `.env`, no ARG with sensitive default, no `chmod 600` of secret
  files); `programmatic` for V1.1 (scan image layers for high-entropy
  strings, common key prefixes).

### I-5: Multi-process images include a supervisor that handles SIGTERM and reaps zombies

- **Why:** When the combined image runs all 3 agents in one container,
  systemd is not available; PID 1 must be a supervisor (s6-overlay, dumb-init,
  tini, or equivalent), not bash, not the first agent. Without a supervisor,
  SIGTERM doesn't propagate cleanly and zombie children accumulate.
- **Check:** `programmatic` — `ncz agent install` inspects the image's
  `Config.Entrypoint`; refuses combined-mode images whose entrypoint isn't on
  an allowlist (`tini`, `s6-overlay-suexec`, `dumb-init`, custom-named
  supervisor declared in manifest).

### I-6: Agent binaries live at canonical paths declared in `manifest.yaml`

- **Why:** The deploy tool, ncz CLI, and zcon TUI all assume a stable contract
  for where each agent's binary, config, and state live. Binary path drift
  silently breaks the stack.
- **Check:** `programmatic` — `ncz agent install` reads each agent's
  `manifest.yaml` `binary_path` and verifies the path exists in the image as a
  file with the executable bit set.

---

## §2 Sandbox invariants

These apply when the agent runs under the OpenShell sandbox layer
(`nclawzero-stack:openshell` image, `policy-additions.yaml` active). Naked
deployments satisfy invariants I-1 through I-6 but do not promise §2.

### S-1: Filesystem policy is a whitelist, not a blacklist

- **Why:** Blacklist policy is brittle — every new path in the rootfs is
  implicitly allowed until added. Whitelist forces the operator to explicitly
  declare "this path is reachable," which scales to new agent versions
  cleanly.
- **Check:** `programmatic` — `ncz agent install` parses
  `policy-additions.yaml` `filesystem_policy.read_only` and `read_write`; the
  agent path is reachable if and only if it appears in one of these lists.
  Refuses policies with a `block` or `deny` list as the operative mode.

### S-2: Configuration directory is mounted read-only and Landlock-enforced

- **Why:** `/sandbox/.<agent>` holds the daemon's TOML config. Once written
  by the install flow, the agent process must not be able to mutate it; that
  prevents a runtime compromise from rewriting credentials, channels, or
  policy. Landlock provides the kernel-level enforcement.
- **Check:** `programmatic` — `policy-additions.yaml` must list
  `/sandbox/.<agent>` under `filesystem_policy.read_only` AND
  `landlock.compatibility` must be `enforce` or `best_effort`. `ncz agent
  install` refuses bundles where the config dir is in `read_write` or where
  Landlock is `disabled`.

### S-3: Network egress is allowlisted by host + port + path, with binary scoping

- **Why:** The default-deny network posture is the OpenShell policy layer's
  most operationally important property. Every approved endpoint is named:
  agent-vendor APIs, observability sinks, model providers. Drift here means
  silent data exfiltration.
- **Check:** `programmatic` — `policy-additions.yaml` `network_policies.*`
  must be a non-empty list; each entry must have `enforcement: enforce` (not
  `monitor` or `audit-only`); each must scope `binaries:` to specific
  agent-runtime executables, not allow `*`.

### S-4: WASM plugins are loaded from a read-only mount

- **Why:** Plugins extend the agent's policy decisions. A writable plugin
  directory is a privilege-escalation vector — one tool-call writes a new
  plugin, the next tool-call gets new policy authority.
- **Check:** `programmatic` — `manifest.yaml` `plugin_path` (or equivalent
  field) must resolve to a path under `filesystem_policy.read_only`. `ncz
  agent install` enforces and refuses bundles where the plugin directory is
  read-write.

### S-5: Privileged probe / management endpoints bind only to localhost

- **Why:** An agent's `/admin`, `/metrics-internal`, debugger endpoints, etc.
  must not be reachable from off-host. Public-facing surface is restricted to
  the agent's declared `forward_ports` (e.g., 42617 for zeroclaw). Anything
  else listens on `127.0.0.1` or a unix domain socket.
- **Check:** `manual` for V1.0 (audit each agent's documented ports vs.
  `manifest.yaml` `forward_ports`); `programmatic` for V1.1 if a structural
  check via `ss -tlnp` post-install becomes feasible.

---

## §3 Install-flow invariants

These apply to the `ncz agent install` / `ncz agent enable` /
`ncz agent disable` operations that lay down quadlets and start services.
Operator-facing properties.

### F-1: OCI image is verified by digest before `podman load`

- **Why:** Catalog images come from the registry, the fleet cache, or a USB
  key. Each path can be tampered. The catalog manifest declares an
  expected SHA256 per image; install refuses if the actual digest doesn't
  match.
- **Check:** `programmatic` — `ncz agent install` computes
  `sha256sum image.oci.tar` and compares against the per-image entry in
  `agents/CATALOG.json` (a new file V1.0 introduces). Mismatch is a hard
  refuse, not a warn.

### F-2: Quadlet content is rendered from canonical templates, never hand-edited

- **Why:** Quadlets are the contract between the deploy tool and systemd. A
  hand-edited `/etc/containers/systemd/zeroclaw.container` defeats the
  reproducibility property: a re-run of `ncz agent install` would clobber
  the edits, but the operator might not know to expect it.
- **Check:** `programmatic` — `ncz agent install` writes a
  `# ncz: managed (do not edit)` header at the top of every quadlet it
  emits. On a re-run, refuses to overwrite a quadlet whose existing content
  doesn't carry this header (operator must `--force` or rename the file).

### F-3: Re-runs are convergent — same input + same on-disk state = no-op

- **Why:** The operator should be able to run `ncz agent install` after
  every reboot, after a partial deploy, after a network blip — and have it
  do nothing if everything is already in the desired state. The alternative
  (sentinel files marking "already done") drifts the moment the on-disk
  state changes underneath.
- **Check:** `programmatic` — install plan compares `(expected hash,
  expected content)` against `(actual hash, actual content)` for each
  artifact (image, quadlet, env file, loader script); skips writes when
  matched.

### F-4: Secrets in `agent-env` never appear in stdout, stderr, or log files

- **Why:** Operators copy-paste deploy output into chat. CI captures logs.
  An API key surfaced in a verbose deploy log is a leaked credential.
- **Check:** `programmatic` — `ncz agent install` filters all values from
  `/etc/nclawzero/agent-env` through a redaction layer before any logging
  or stdout emission; redacted form is `KEY=<redacted len=N>` matching the
  established memory-doc convention. Refuses to install if the redaction
  filter can't be initialized.

### F-5: Install flow refuses to run as root from an interactive shell

- **Why:** `ncz agent install` is the privileged half of the deploy. Running
  it from a remote SSH session with a logged-in root account silently
  loses the audit trail of who did what. Operator's normal flow is `ncz
  agent install` as `ncz` user with passwordless sudo configured for the
  specific commands; `ncz agent install` invokes `sudo` per-step.
- **Check:** `programmatic` — `ncz agent install` checks `getuid()` and
  `getppid()` ancestry; refuses to start if effective UID is 0 unless
  `--allow-root` is passed (for genuinely root-owned commissioning
  scenarios like first-boot service).

### F-6: `ncz agent disable` and `ncz agent uninstall` leave the host in a
known clean state

- **Why:** Operators who want to back out of a deploy must be able to do so
  cleanly. Half-removed quadlets + lingering podman volumes + stale
  systemd units are the classic "I tried to clean up and now nothing
  works" state.
- **Check:** `programmatic` — `ncz agent uninstall` removes (in order):
  systemd units, quadlet files, podman containers and volumes, baked
  agent-images, `/var/lib/nclawzero/openclaw-home` and friends, agent-env
  if `--full`. `ncz agent disable` is the lighter form: stops + masks
  units, leaves the artifacts in place for re-enable.

---

## How to add a new invariant

Append a new section in the appropriate layer (§1/§2/§3) using the same
shape: ID, statement, why, check. Bump the document's version (top of file).
Update `agents/CATALOG.json` if the invariant changes the image-attestation
contract.

Invariants are versioned with the rest of the agent stack. When the
`nclawzero-stack:N.N.N` image catalog publishes, the invariants doc at the
same tag is the contract that audit + install enforce against.

## Cross-references

- `nclawzero/distro/agents/<agent>/manifest.yaml` — per-agent runtime contract
- `nclawzero/distro/agents/<agent>/policy-additions.yaml` — sandbox policy
- `nclawzero/distro/agents/<agent>/Dockerfile` — image bake (per-agent today;
  `Dockerfile.combined.{naked,openshell}` is V1.0 work)
- `nclawzero/ncz-tools/ncz/src/cmd/agent.rs` — install-flow implementation
  (V1.0 work)
- `nclawzero/ncz-tools/ncz/tests/invariants.rs` — programmatic-check coverage
  for each invariant marked `Check: programmatic`
