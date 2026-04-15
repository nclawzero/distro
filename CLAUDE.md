<!--
  SPDX-FileCopyrightText: Copyright (c) 2026 Jason Perlow. All rights reserved.
  SPDX-License-Identifier: Apache-2.0
-->

# Agent Instructions

## Project Overview

nclawzero is a research project exploring how to run ZeroClaw agents inside OpenShell sandboxes on memory-constrained and resource-constrained devices for edge and embedded deployments. Forked from NVIDIA NemoClaw but independently maintained. It provides CLI tooling, a blueprint for sandbox orchestration, and security hardening.

**Status:** Alpha (March 2026+). Interfaces may change without notice.

## Agent Skills

This repo ships agent skills under `.agents/skills/`, organized into three audience buckets: `nemoclaw-user-*` (end users), `nemoclaw-maintainer-*` (project maintainers), and `nemoclaw-contributor-*` (codebase contributors). Load the `nemoclaw-skills-guide` skill for a full catalog and quick decision guide mapping tasks to skills.

## Architecture

| Path | Language | Purpose |
|------|----------|---------|
| `bin/` | JavaScript (CJS) | CLI launcher (`nemoclaw.js`) and small compatibility helpers |
| `src/lib/` | TypeScript | Core CLI logic: onboard, credentials, inference, policies, preflight, runner |
| `nemoclaw/` | TypeScript | Plugin project (Commander CLI extension for OpenClaw) |
| `nemoclaw/src/blueprint/` | TypeScript | Runner, snapshot, SSRF validation, state management |
| `nemoclaw/src/commands/` | TypeScript | Slash commands, migration state |
| `nemoclaw/src/onboard/` | TypeScript | Onboarding config |
| `nemoclaw-blueprint/` | YAML | Blueprint definition and network policies |
| `scripts/` | Bash/JS/TS | Install helpers, setup, automation, E2E tooling |
| `test/` | JavaScript (ESM) | Root-level integration tests (Vitest) |
| `test/e2e/` | Bash/JS | End-to-end tests (Brev cloud instances) |
| `docs/` | Markdown (MyST) | User-facing docs (Sphinx) |
| `k8s/` | YAML | Kubernetes deployment manifests |

## Quick Reference

| Task | Command |
|------|---------|
| Install all deps | `npm install && cd nemoclaw && npm install && npm run build && cd .. && cd nemoclaw-blueprint && uv sync && cd ..` |
| Build plugin | `cd nemoclaw && npm run build` |
| Watch mode | `cd nemoclaw && npm run dev` |
| Run all tests | `npm test` |
| Run plugin tests | `cd nemoclaw && npm test` |
| Run all linters | `make check` |
| Run all hooks manually | `npx prek run --all-files` |
| Type-check CLI | `npm run typecheck:cli` |
| Auto-format | `make format` |
| Build docs | `make docs` |
| Serve docs locally | `make docs-live` |

## Key Architecture Decisions

### Dual-Language Stack

- **CLI and plugin**: TypeScript (`src/`, `nemoclaw/src/`) with a small CommonJS launcher in `bin/`; ESM in `test/`
- **Blueprint**: YAML configuration (`nemoclaw-blueprint/`)
- **Docs**: Sphinx/MyST Markdown
- **Tooling scripts**: Bash and Python

The `bin/` directory uses CommonJS intentionally for the launcher and a few compatibility helpers so the CLI still has a stable executable entry point. The main CLI implementation lives in `src/` and compiles to `dist/`. The `nemoclaw/` plugin uses TypeScript and requires compilation.

### Testing Strategy

Tests are organized into three Vitest projects defined in `vitest.config.ts`:

1. **`cli`** — `test/**/*.test.{js,ts}` — integration tests for CLI behavior
2. **`plugin`** — `nemoclaw/src/**/*.test.ts` — unit tests co-located with source
3. **`e2e-brev`** — `test/e2e/brev-e2e.test.js` — cloud E2E (requires `BREV_API_TOKEN`)

When writing tests:

- Root-level tests (`test/`) use ESM imports
- Plugin tests use TypeScript and are co-located with their source files
- Mock external dependencies; don't call real NVIDIA APIs in unit tests
- E2E tests run on ephemeral Brev cloud instances

### Security Model

NemoClaw isolates agents inside OpenShell sandboxes with:

- Network policies (`nemoclaw-blueprint/policies/`) controlling egress
- Credential sanitization to prevent leaks
- SSRF validation (`nemoclaw/src/blueprint/ssrf.ts`)
- Docker capability drops and process limits

Security-sensitive code paths require extra test coverage.

## Code Style and Conventions

### Commit Messages

Conventional Commits required. Enforced by commitlint via prek `commit-msg` hook.

```text
<type>(<scope>): <description>
```

Types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `ci`, `perf`, `merge`

### SPDX Headers

Every source file must include an SPDX license header. The pre-commit hook auto-inserts them:

```javascript
// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0
```

For shell scripts use `#` comments. For Markdown use HTML comments.

### JavaScript

- `bin/` launcher and remaining `scripts/*.js`: **CommonJS** (`require`/`module.exports`), Node.js 22.16+
- `test/`: **ESM** (`import`/`export`)
- ESLint config in `eslint.config.mjs`
- Cyclomatic complexity limit: 20 (ratcheting down to 15)
- Unused vars pattern: prefix with `_`

### TypeScript

- Plugin code in `nemoclaw/src/` with its own ESLint config
- CLI type-checking via `tsconfig.cli.json`
- Plugin type-checking via `nemoclaw/tsconfig.json`

### Shell Scripts

- ShellCheck enforced (`.shellcheckrc` at root)
- `shfmt` for formatting
- All scripts must have shebangs and be executable

### No External Project Links

Do not add links to third-party code repositories, community collections, or unofficial resources. Links to official tool documentation (Node.js, Python, uv) are acceptable.

## Git Hooks (prek)

All hooks managed by [prek](https://prek.j178.dev/) (installed via `npm install`):

| Hook | What runs |
|------|-----------|
| **pre-commit** | File fixers, formatters, linters, Vitest (plugin) |
| **commit-msg** | commitlint (Conventional Commits) |
| **pre-push** | TypeScript type check (tsc --noEmit for plugin, JS, CLI) |

## Working with This Repo

### Before Making Changes

1. Read `CONTRIBUTING.md` for the full contributor guide
2. Run `make check` to verify your environment is set up correctly
3. Check that `npm test` passes before starting

### Common Patterns

**Adding a CLI command:**

- Entry point: `bin/nemoclaw.js` (launches the compiled CLI in `dist/`)
- Main CLI implementation lives in `src/lib/` and compiles to `dist/lib/`
- Add tests in `test/`

**Adding a plugin feature:**

- Source: `nemoclaw/src/`
- Co-locate tests as `*.test.ts`
- Build with `cd nemoclaw && npm run build`

**Adding a network policy preset:**

- Add YAML to `nemoclaw-blueprint/policies/presets/`
- Follow existing preset structure (see `slack.yaml`, `discord.yaml`)

### Gotchas

- `npm install` at root triggers `prek install` which sets up git hooks. If hooks fail, check that `core.hooksPath` is unset: `git config --unset core.hooksPath`
- The `nemoclaw/` subdirectory has its own `package.json`, `node_modules/`, and ESLint config — it's a separate npm project
- SPDX headers are auto-inserted by pre-commit hooks; don't worry about adding them manually
- Coverage thresholds are ratcheted in `ci/coverage-threshold-*.json` — new code should not decrease CLI or plugin coverage
- The `.claude/skills` symlink points to `.agents/skills` — both paths resolve to the same content

## Documentation

- Source of truth: `docs/` directory
- `.agents/skills/nemoclaw-user-*/*.md` is **autogenerated** — never edit directly
- After changing docs, regenerate skills:

  ```bash
  python3 scripts/docs-to-skills.py docs/ .agents/skills/ --prefix nemoclaw-user
  ```

- Follow style guide in `docs/CONTRIBUTING.md`

## PR Requirements

- Create feature branch from `main`
- Run `make check` and `npm test` before submitting
- Follow PR template (`.github/PULL_REQUEST_TEMPLATE.md`)
- Update docs for any user-facing behavior changes
- No secrets, API keys, or credentials committed
- Limit open PRs to fewer than 10

---

## ZeroClaw Agent — Development State

> This section documents the in-progress ZeroClaw agent work as of April 2026.
> All code lives on the `perlowjanv:nemoclawzero` branch (fork of `NVIDIA/NemoClaw`).
> A PR to `NVIDIA/NemoClaw` is blocked pending contributor access being granted.

### What is ZeroClaw

ZeroClaw is a Rust-based AI agent runtime (analogous to Hermes, which is Python-based).
It binds to port 42617, uses a TOML config, exposes `GET /health → {"status":"ok"}`,
and loads a NemoClaw WASM plugin compiled from `agents/zeroclaw/plugin/` via the Extism PDK.

### Files Added on `perlowjanv:nemoclawzero`

| Path | Purpose |
|------|---------|
| `agents/zeroclaw/Dockerfile.base` | Real base image: pulls `node:22-slim` from Docker Hub, downloads `zeroclaw` binary + `gosu` from GitHub Releases |
| `agents/zeroclaw/Dockerfile` | Real sandbox image: Stage 1 compiles WASM plugin with `rust:1.87-bookworm`; Stage 2 generates `config.toml` with `node --experimental-strip-types` |
| `agents/zeroclaw/start.sh` | Container entrypoint: config integrity check, privilege separation via gosu, capability drops |
| `agents/zeroclaw/generate-config.ts` | Generates `config.toml` from build-arg env vars at image build time |
| `agents/zeroclaw/plugin/` | Rust source for the NemoClaw WASM plugin (Extism PDK) |
| `agents/zeroclaw/stub/zeroclaw` | Fake zeroclaw binary (Python HTTP server) for restricted-network testing |
| `agents/zeroclaw/stub/gosu` | No-op gosu stub (drops user arg, execs rest) |
| `agents/zeroclaw/Dockerfile.stub.base` | Stub base image: uses host binaries via `docker import`, no Docker Hub required |
| `agents/zeroclaw/Dockerfile.stub` | Stub sandbox image: placeholder WASM, Python config generation (no Node v22 required) |
| `scripts/build-stub-images.sh` | Builds stub images from host Ubuntu 24.04 binaries for restricted-network environments |
| `scripts/zeroclaw-e2e.sh` | **Primary E2E script** — standalone, no brev required. Runs on any system with full internet. Accepts `--repo PATH` and `--token PAT`. |
| `scripts/brev-e2e-bootstrap.sh` | E2E bootstrap designed to run ON a Brev cloud instance |
| `scripts/brev-e2e-run.sh` | Orchestration wrapper: checks Brev instance status, calls bootstrap via `brev exec`, copies results |

### TODO — ZeroClaw Live Validation

The stub-based local installer flow has been tested end-to-end on OmniStation. The real images (real `zeroclaw` binary, real WASM compile) have **not yet been validated** in a live run. Outstanding items:

1. **Run `scripts/zeroclaw-e2e.sh`** on a system with full internet access (Docker Hub + GitHub Releases reachable). See [Testing Environments](#testing-environments) below.
2. Verify `GET /health` returns `{"status":"ok"}` without `"stub"` marker.
3. Verify container logs contain `Deployed verified config` (config integrity check).
4. Once validated, promote real images to `ghcr.io/nvidia/nemoclaw/` and remove the stub Dockerfiles.
5. Submit PR to `NVIDIA/NemoClaw` once contributor access is granted.

### Stub vs Real Images

| | Stub images | Real images |
|---|---|---|
| Built by | `scripts/build-stub-images.sh` | `agents/zeroclaw/Dockerfile.base` + `Dockerfile` |
| Base | `nemoclaw-stub-rootfs:latest` (host Ubuntu binaries via `docker import`) | `node:22-slim` from Docker Hub |
| `zeroclaw` binary | Python HTTP server (`stub/zeroclaw`) | Real Rust binary from GitHub Releases |
| WASM plugin | 8-byte placeholder (`\x00asm\x01\x00\x00\x00`) | Compiled from `plugin/` via `rust:1.87-bookworm` |
| Docker label | `io.nemoclaw.stub=true` | not set |
| Network required | None (all from host) | Docker Hub + GitHub Releases CDN |
| Use when | Local testing on NVIDIA OmniStation or other CDN-blocked networks | Live validation, production |

---

## Testing Environments

### Environment Matrix

| Environment | Docker Hub | GitHub Releases | git push | `brev exec` | Use for |
|---|---|---|---|---|---|
| **NVIDIA OmniStation** | ✗ blocked | ✗ blocked | ✗ 503 | ✗ needs device reg | Unit tests, stub-based installer test |
| **NVIDIA corpnet + internet** | ✓ | ✓ | varies | n/a | Live E2E (`scripts/zeroclaw-e2e.sh`) |
| **Brev cloud GPU instance** | ✓ | ✓ | ✓ | target only | Live E2E (run bootstrap directly) |
| **Developer workstation** | ✓ | ✓ | ✓ | ✓ if registered | Full workflow |

### Running the Live E2E Test

On any system with full internet access:

```bash
# Option 1: from an existing local checkout
scripts/zeroclaw-e2e.sh --repo /path/to/nclawzero

# Option 2: clone from ARGONAS first
git clone root@192.168.207.101:/mnt/datapool/git/nclawzero.git
cd nclawzero && scripts/zeroclaw-e2e.sh --repo .
```

Results are written to `/tmp/zeroclaw-e2e-results.txt` and printed to stdout.

### Running the Stub-Based Installer Test (OmniStation / CDN-blocked networks)

```bash
# 1. Build stub images (one-time, ~5 min)
scripts/build-stub-images.sh

# 2. Run the installer with stub images in place
nemoclaw onboard --agent zeroclaw

# 3. Verify health probe
curl http://localhost:42617/health
# → {"status":"ok","version":"0.6.9-stub","stub":true}
```

### OmniStation-Specific Gotchas

- **`brev register` requires sudo + Entra ID Hello PIN (PAM)** — non-interactive device registration is not possible. `brev exec` and `brev copy` will not work from OmniStation. Use the browser-based terminal at brev.nvidia.com instead, or run E2E from a registered workstation.
- **Docker Hub / GitHub Releases CDN blocked** — use stub images for local testing; real images require an external system.
- **`brev ls` and `brev healthcheck` work** — brev API is reachable; only SSH-based operations (exec, copy, port-forward) are blocked.

---

## Repository Topology

```text
NVIDIA/NemoClaw (upstream)           — reference upstream
ARGONAS bare repo                    — LAN source of truth
  /mnt/datapool/git/nclawzero.git
     ↕ origin (SSH)
  zeropi (.56) ~/nclawzero           — min footprint test target
  clawpi (.54) ~/nclawzero           — full-featured test target
```

GitLab mirror: https://gitlab-master.nvidia.com/jperlow/nclawzero

All development is on the `nemoclawzero` branch. Push to ARGONAS, sync to GitLab as needed.
