---
name: "nclawzero-zeroclaw-security"
description: "Security hardening reference for ZeroClaw containers on nclawzero. Covers container privilege separation with gosu and the gateway user, capability drops, config integrity verification via sha256sum, symlink validation, network policies, and .env file permissions. Use when reviewing container security, hardening a ZeroClaw deployment, or auditing sandbox security controls."
---

<!-- SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved. -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- SPDX-FileCopyrightText: Copyright (c) 2026 Jason Perlow. All rights reserved. -->

# ZeroClaw Security Hardening Reference

Security architecture and hardening controls for ZeroClaw containers running inside NemoClaw/OpenShell sandboxes on nclawzero.

## Security Model Overview

ZeroClaw runs inside an OpenShell sandbox with multiple defense layers:

1. **Container isolation** — Docker container with restricted capabilities
2. **Privilege separation** — Gateway process runs as a dedicated user
3. **Config integrity** — SHA-256 hash verification at startup
4. **Landlock LSM** — Filesystem access control (read-only config, writable data)
5. **Network policies** — Egress restricted to declared endpoints only
6. **Symlink validation** — Prevents symlink attacks against config paths

## Container Privilege Separation

The ZeroClaw sandbox uses three user contexts:

| User | Purpose | Filesystem Access |
|------|---------|-------------------|
| `root` | Startup initialization, symlink hardening, gosu delegation | Full (during init only) |
| `gateway` | Runs the ZeroClaw gateway process | Read config, write data dirs |
| `sandbox` | Agent operations inside the sandbox shell | Read/write `/sandbox`, no config writes |

### Startup Flow

1. Container starts as `root`
2. `start.sh` verifies config integrity
3. Copies verified config to the writable data directory
4. Validates all symlinks in `/sandbox/.zeroclaw`
5. Hardens symlinks with `chattr +i` (if available)
6. Changes ownership of writable dirs to `gateway:sandbox`
7. Drops to `gateway` user via `gosu` to launch the ZeroClaw gateway
8. Gateway process inherits the open log file descriptor

### gosu Usage

The `gosu` binary runs as `root` and exec-replaces itself with the target user, avoiding the PID and signal-forwarding issues of `su` or `sudo` in containers:

```bash
# In start.sh — starts gateway as 'gateway' user
ZEROCLAW_HOME="${ZEROCLAW_WRITABLE}" \
  nohup gosu gateway "$ZEROCLAW" gateway start --config-dir "${ZEROCLAW_WRITABLE}" \
  >/tmp/gateway.log 2>&1 &
```

If running as non-root (rootless containers), privilege separation is disabled and the gateway runs as the current user.

## Capability Drops

The entrypoint drops unnecessary Linux capabilities at startup using `capsh`. This reduces the kernel attack surface available to the container process.

Capabilities dropped:

| Capability | Why Dropped |
|------------|-------------|
| `cap_net_raw` | No raw socket access needed; prevents packet sniffing |
| `cap_dac_override` | Enforces file permission checks; prevents bypassing DAC |
| `cap_sys_chroot` | No chroot operations needed |
| `cap_fsetid` | No setuid/setgid bit manipulation needed |
| `cap_setfcap` | No capability-setting on files needed |
| `cap_mknod` | No device node creation needed |
| `cap_audit_write` | No audit log writing needed |
| `cap_net_bind_service` | Gateway uses port 42617 (unprivileged); no low-port binding needed |

Implementation in `start.sh`:

```bash
if [ "${NEMOCLAW_CAPS_DROPPED:-}" != "1" ] && command -v capsh >/dev/null 2>&1; then
  if capsh --has-p=cap_setpcap 2>/dev/null; then
    export NEMOCLAW_CAPS_DROPPED=1
    exec capsh \
      --drop=cap_net_raw,cap_dac_override,cap_sys_chroot,cap_fsetid,cap_setfcap,cap_mknod,cap_audit_write,cap_net_bind_service \
      -- -c 'exec /usr/local/bin/nemoclaw-start "$@"' -- "$@"
  fi
fi
```

The `NEMOCLAW_CAPS_DROPPED` environment variable prevents re-entry when `capsh` exec-replaces the script.

## Config Integrity Verification

At image build time, the Dockerfile computes a SHA-256 hash of `config.toml` and stores it in `/sandbox/.zeroclaw/.config-hash`:

```dockerfile
RUN sha256sum /sandbox/.zeroclaw/config.toml \
    > /sandbox/.zeroclaw/.config-hash \
    && chmod 444 /sandbox/.zeroclaw/.config-hash \
    && chown root:root /sandbox/.zeroclaw/.config-hash
```

At container startup, `start.sh` verifies the hash before deploying the config:

```bash
verify_config_integrity() {
  local hash_file="${ZEROCLAW_IMMUTABLE}/.config-hash"
  if [ ! -f "$hash_file" ]; then
    echo "[SECURITY] Config hash file missing — refusing to start" >&2
    return 1
  fi
  if ! (cd "${ZEROCLAW_IMMUTABLE}" && sha256sum -c "$hash_file" --status 2>/dev/null); then
    echo "[SECURITY] Config integrity check FAILED — config may have been tampered with" >&2
    return 1
  fi
}
```

If the check fails, the container refuses to start. This detects any modification to `config.toml` after the image was built — whether through volume mounts, layer manipulation, or runtime tampering.

## Symlink Validation

The immutable config directory (`/sandbox/.zeroclaw`) may contain symlinks pointing to the writable data directory (`/sandbox/.zeroclaw-data`). At startup, every symlink is validated:

```bash
validate_zeroclaw_symlinks() {
  for entry in /sandbox/.zeroclaw/*; do
    [ -L "$entry" ] || continue
    target="$(readlink -f "$entry" 2>/dev/null || true)"
    expected="/sandbox/.zeroclaw-data/$(basename "$entry")"
    if [ "$target" != "$expected" ]; then
      echo "[SECURITY] Symlink $entry points to unexpected target: $target" >&2
      return 1
    fi
  done
}
```

After validation, symlinks are hardened with the immutable attribute (`chattr +i`) to prevent runtime modification. If `chattr` is not available (some container runtimes strip it), the script falls back to DAC permissions plus Landlock.

## Network Policies

ZeroClaw sandboxes use a declarative network policy defined in `agents/zeroclaw/policy-additions.yaml`. The policy follows deny-by-default with explicit allowlists.

### Policy Structure

```yaml
version: 1

filesystem_policy:
  read_only:
    - /sandbox/.zeroclaw              # Immutable config
  read_write:
    - /sandbox/.zeroclaw-data         # Writable agent state

network_policies:
  nvidia:
    endpoints:
      - host: integrate.api.nvidia.com
        port: 443
        rules:
          - allow: { method: POST, path: "/v1/chat/completions" }
          - allow: { method: GET, path: "/v1/models" }
    binaries:
      - { path: /usr/local/bin/zeroclaw }
```

### Declared Network Endpoints

| Policy | Hosts | Purpose |
|--------|-------|---------|
| `claude_code` | api.anthropic.com, statsig.anthropic.com, sentry.io | Claude Code agent |
| `nvidia` | integrate.api.nvidia.com, inference-api.nvidia.com | NVIDIA inference |
| `github` | github.com, api.github.com | Git operations |
| `zeroclaw_labs` | zeroclaw-labs.com, api.zeroclaw-labs.com | ZeroClaw update checks |
| `telegram` | api.telegram.org | Telegram messaging |
| `discord` | discord.com, gateway.discord.gg, cdn.discordapp.com | Discord messaging |
| `slack` | slack.com, wss-primary.slack.com | Slack messaging |

Each policy binds network access to specific binaries. For example, only `/usr/local/bin/zeroclaw` can reach `api.telegram.org` — the sandbox shell cannot.

### Customizing Network Policies

To add endpoints for your deployment, modify `agents/zeroclaw/policy-additions.yaml` and rebuild the sandbox image. The policy is baked into the image at build time.

## .env File Permissions

API keys are stored in `~/.zeroclaw/.env` on the host. This file must be readable only by the owner:

```bash
chmod 600 ~/.zeroclaw/.env
```

Inside the sandbox, credentials flow through OpenShell's L7 proxy — the sandbox never receives the raw API key. The proxy intercepts inference traffic at `inference.local` and injects the provider credential on the host side.

## Build-Time Hardening

The Dockerfile applies additional hardening:

| Control | Implementation |
|---------|----------------|
| Config locked to root | `chown root:root /sandbox/.zeroclaw` |
| Config read-only | `chmod 444 /sandbox/.zeroclaw/config.toml` |
| Build tools removed | `apt-get remove gcc g++ make netcat` |
| Cache cleared | `rm -rf /sandbox/.cache` |
| Separate config generation | Script file instead of inline code prevents build-arg injection |
| Process limits | `ulimit -Su 512` and `ulimit -Hu 512` set at startup |
| PATH locked | `export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"` |

## Configure Guard

Inside the sandbox, a shell function intercepts `zeroclaw onboard` and `zeroclaw service` commands, blocking config modifications:

```bash
zeroclaw() {
  case "$1" in
    onboard|service)
      echo "Error: 'zeroclaw $1' cannot modify config inside the sandbox." >&2
      return 1
      ;;
  esac
  command zeroclaw "$@"
}
```

This is injected into `.bashrc` and `.profile` at startup.

## Related Skills

- `nclawzero-zeroclaw-get-started` — Installation and first run
- `nclawzero-zeroclaw-config` — Full configuration reference
- `nclawzero-testing` — Testing guide (includes security-related E2E tests)
- `nclawzero-skills-guide` — Skills catalog for nclawzero
