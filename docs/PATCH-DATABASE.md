# nclawzero Patch Database

Maintained inventory of all modifications to upstream NemoClaw and new overlay files.
This is the authoritative reference for what nclawzero changes and why.

**Upstream base**: NVIDIA/NemoClaw `main` @ c333d96
**nclawzero branch**: `nclawzero-rebase`
**Last updated**: 2026-04-16

---

## Patch Categories

### P: Patches (17 files modified in upstream NemoClaw)
### O: Overlays (40 new files added, not in upstream)

---

## Patches — Security Hardening

| ID | File | Lines | Description | PR candidate |
|----|------|-------|-------------|-------------|
| P-SEC-001 | `nemoclaw/src/blueprint/snapshot.ts` | +32 | Symlink protection: `assertNotSymlink()` guard before cpSync, skip symlinks in collectFiles(), path bounds validation | Yes — upstream bug fix |
| P-SEC-002 | `nemoclaw/src/blueprint/snapshot.test.ts` | +45 | Tests for symlink attack prevention (3 tests) | Yes — ships with P-SEC-001 |
| P-SEC-003 | `nemoclaw/src/onboard/config.ts` | +11 | Credential file permissions: writeFileSync mode 0o600 + chmodSync belt-and-suspenders | Yes — upstream bug fix |
| P-SEC-004 | `nemoclaw/src/onboard/config.test.ts` | +23 | Tests for file permission enforcement (2 tests) | Yes — ships with P-SEC-003 |

## Patches — ZeroClaw Agent Integration

| ID | File | Lines | Description | PR candidate |
|----|------|-------|-------------|-------------|
| P-ZC-001 | `src/lib/agent-defs.ts` | +14 | Register ZeroClaw as agent runtime alongside Hermes | Yes — feature PR |
| P-ZC-002 | `src/lib/agent-runtime.ts` | +8 | ZeroClaw runtime detection and lifecycle hooks | Yes — ships with P-ZC-001 |
| P-ZC-003 | `src/nemoclaw.ts` | +84 | CLI integration: zeroclaw onboard, ClawHub skill delegation | Yes — ships with P-ZC-001 |

## Patches — CI/Build

| ID | File | Lines | Description | PR candidate |
|----|------|-------|-------------|-------------|
| P-CI-001 | `.github/workflows/base-image.yaml` | +72 | ZeroClaw base image build workflow | Maybe — depends on ZeroClaw acceptance |
| P-CI-002 | `.github/workflows/nightly-e2e.yaml` | +35 | ZeroClaw E2E in nightly matrix | Maybe — depends on ZeroClaw acceptance |

## Patches — Documentation / Misc

| ID | File | Lines | Description | PR candidate |
|----|------|-------|-------------|-------------|
| P-DOC-001 | `README.md` | +287/-200 | nclawzero project description, ZeroClaw agent docs, testing environments | No — nclawzero-specific |
| P-DOC-002 | `.agents/skills/nemoclaw-user-reference/references/commands.md` | +7 | ZeroClaw commands in user reference | Yes — ships with P-ZC-001 |
| P-DOC-003 | `agents/hermes/manifest.yaml` | +5 | Cross-reference to ZeroClaw in Hermes manifest | Yes — ships with P-ZC-001 |
| P-DOC-004 | `docs/conf.py` | +6 | Sphinx config for ZeroClaw docs | Maybe |
| P-MISC-001 | `.gitignore` | +1 | Ignore nclawzero build artifacts | No — nclawzero-specific |
| P-MISC-002 | `test/credentials.test.ts` | +2 | Test fixture adjustment for ZeroClaw agent | Yes — ships with P-ZC-001 |
| P-MISC-003 | `test/runtime-shell.test.ts` | +1 | Test fixture for ZeroClaw runtime | Yes — ships with P-ZC-001 |
| P-MISC-004 | `test/skills-frontmatter.test.ts` | +7 | Frontmatter validation for nclawzero skills | No — nclawzero-specific |

---

## Overlays — ZeroClaw Agent (Core)

| ID | File | Lines | Description |
|----|------|-------|-------------|
| O-ZC-001 | `agents/zeroclaw/manifest.yaml` | 103 | Agent manifest: ports, health probe, config, auth, inference |
| O-ZC-002 | `agents/zeroclaw/generate-config.ts` | 113 | TOML config generator from build-args |
| O-ZC-003 | `agents/zeroclaw/start.sh` | 365 | Container entrypoint: integrity check, capsh, gosu, symlink validation |
| O-ZC-004 | `agents/zeroclaw/Dockerfile.base` | 105 | Base image: node:22-slim pinned, ZeroClaw binary, gosu |
| O-ZC-005 | `agents/zeroclaw/Dockerfile` | 106 | Sandbox image: WASM compile, config gen |
| O-ZC-006 | `agents/zeroclaw/Dockerfile.stub` | 200 | Stub sandbox image for offline testing |
| O-ZC-007 | `agents/zeroclaw/Dockerfile.stub.base` | 71 | Stub base image from host binaries |
| O-ZC-008 | `agents/zeroclaw/plugin/` | 177 | WASM plugin (Rust, Extism PDK) — Cargo.toml, manifest.toml, lib.rs |
| O-ZC-009 | `agents/zeroclaw/policy-additions.yaml` | 192 | Network policy additions for ZeroClaw egress |
| O-ZC-010 | `agents/zeroclaw/policy-permissive.yaml` | 109 | Permissive network policy for development |
| O-ZC-011 | `agents/zeroclaw/stub/zeroclaw` | 83 | Python fake binary for restricted-network testing |
| O-ZC-012 | `agents/zeroclaw/stub/gosu` | 33 | No-op gosu stub |

## Overlays — Tests

| ID | File | Lines | Description |
|----|------|-------|-------------|
| O-TEST-001 | `test/zeroclaw-security.test.ts` | 417 | Dockerfile injection, capability drops, secrets, WASM safety |
| O-TEST-002 | `test/zeroclaw-config-generation.test.ts` | 383 | TOML output, provider URLs, gateway config |
| O-TEST-003 | `test/zeroclaw-start.test.ts` | 390 | Config integrity, gosu, proxy detection, health probe |
| O-TEST-004 | `test/security-hardening.test.ts` | 311 | P1 hardening: symlinks, capabilities, provenance, web auth |
| O-TEST-005 | `test/skill-compatibility.test.ts` | 205 | Cross-platform skill format compatibility |
| O-TEST-006 | `nemoclaw/src/lib/subprocess-env.test.ts` | 242 | P0: credential isolation boundary (61 tests) |
| O-TEST-007 | `src/lib/agent-runtime.test.ts` | 162 | Agent runtime detection and lifecycle |
| O-TEST-008 | `test/e2e/test-zeroclaw-e2e.sh` | 595 | Standalone E2E (no Brev required) |
| O-TEST-009 | `test/e2e/test-zeroclaw-sandbox-operations.sh` | 496 | Sandbox isolation E2E |

## Overlays — Scripts & Tooling

| ID | File | Lines | Description |
|----|------|-------|-------------|
| O-SCRIPT-001 | `scripts/zeroclaw-e2e.sh` | 312 | Primary ZeroClaw E2E script |
| O-SCRIPT-002 | `scripts/zeroclaw-provider-harness.sh` | 507 | Provider validation harness |
| O-SCRIPT-003 | `scripts/build-stub-images.sh` | 296 | Build stub images from host binaries |
| O-SCRIPT-004 | `scripts/deploy-test-target.sh` | 368 | Deploy to SSH/Brev/local test target |
| O-SCRIPT-005 | `scripts/test-harness.py` | 641 | MNEMOS-inspired shard-based test result storage |
| O-SCRIPT-006 | `scripts/brev-e2e-bootstrap.sh` | 212 | Brev cloud E2E bootstrap |
| O-SCRIPT-007 | `scripts/brev-e2e-run.sh` | 97 | Brev E2E orchestration |
| O-SCRIPT-008 | `scripts/agent-sdk-template.mjs` | 789 | NVIDIA inference proxy agent runner |
| O-SCRIPT-009 | `scripts/agent-test-runner.mjs` | 798 | 3-agent parallel test analysis |
| O-SCRIPT-010 | `scripts/agent-quick-audit.mjs` | 115 | Single-agent audit tool |

## Overlays — Skills

| ID | File | Lines | Description |
|----|------|-------|-------------|
| O-SKILL-001 | `.agents/skills/nclawzero-zeroclaw-get-started/SKILL.md` | 206 | Getting started guide |
| O-SKILL-002 | `.agents/skills/nclawzero-zeroclaw-config/SKILL.md` | 279 | Configuration reference |
| O-SKILL-003 | `.agents/skills/nclawzero-zeroclaw-security/SKILL.md` | 232 | Security hardening guide |
| O-SKILL-004 | `.agents/skills/nclawzero-testing/SKILL.md` | 232 | Testing guide |
| O-SKILL-005 | `.agents/skills/nclawzero-skills-guide/SKILL.md` | 81 | Skills catalog |

## Overlays — Documentation

| ID | File | Lines | Description |
|----|------|-------|-------------|
| O-DOC-001 | `docs/NCLAWZERO-COMMAND-SURFACE.md` | 257 | NemoClaw→ZeroClaw integration reference |
| O-DOC-002 | `zeroclaw-agent-audit.md` | 112 | ZeroClaw agent audit findings |

---

## PR Filing Strategy

When GitHub accounts are restored, file PRs in this order:

### Wave 1: Security Fixes (highest merge probability)
1. **P-SEC-001 + P-SEC-002**: Snapshot symlink protection
2. **P-SEC-003 + P-SEC-004**: Credential file permissions

### Wave 2: ZeroClaw Agent Support (feature PR, needs maintainer buy-in)
3. **P-ZC-001 + P-ZC-002 + P-ZC-003 + P-DOC-002 + P-DOC-003**: Full ZeroClaw agent integration

### Wave 3: CI/Build (depends on Wave 2 acceptance)
4. **P-CI-001 + P-CI-002**: CI workflows for ZeroClaw

### Hold: nclawzero-specific patches
- P-DOC-001, P-MISC-001, P-MISC-004 stay in nclawzero patchset, never filed upstream

---

## Totals

| Category | Files | Lines |
|----------|-------|-------|
| Patches (modified upstream) | 17 | +440/-200 |
| Overlays (new files) | 40 | +10,392 |
| **Total delta** | **57** | **+10,832** |
| Upstream PR candidates | 11 files | ~240 lines |
| nclawzero-only patches | 6 files | ~200 lines |
