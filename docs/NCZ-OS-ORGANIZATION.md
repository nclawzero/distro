# ncz-os Repository Organization & Multi-Variant Migration Plan

> Status: **PLAN (approved 2026-06-18)** — execution is phased; this doc lands
> first (doc-first), then the moves happen step by step.
>
> Goal: restructure the `ncz-os` org so the NCZ / nclawzero distribution can
> support **multiple hardware variants** (Cix Sky1 today; Raspberry Pi; NVIDIA
> Jetson later) without duplicating the ~80% of the userland that is
> platform-agnostic.

---

## 1. Principles

1. **One canonical forge.** GitLab `ncz-os/*` is the **source of truth**.
   GitHub + Codeberg (+ the self-hosted ARGONAS bare remotes) are **mirrors**.
   All development pushes to GitLab first; mirrors are kept in lockstep.
2. **Separate "build mechanism" from "userland."** The way an image is built
   differs per platform and cannot be unified:
   - Cix Sky1 → debian-installer / debootstrap netinstall
   - Raspberry Pi → `pi-gen`
   - NVIDIA Jetson → NVIDIA flash / SDK Manager (deferred)
   But the **userland layer** (agents, AI runtime, desktop, branding, CLI) is
   shared. So: **per-variant builders** consume a **shared `distro-core`**.
3. **Registered Yocto layers are frozen.** `meta-cix` is an officially
   registered OpenEmbedded BSP layer with a named maintainer. It is **never
   moved or renamed** by this reorg. Only its layer-index VCS URL may be
   re-pointed, and that is a **maintainer action** (not part of repo moves).
4. **Consistent naming** so new variants slot in predictably (see §4).

---

## 2. Target taxonomy

```
GitLab ncz-os/*  (CANONICAL)  ──mirror──▶  GitHub + Codeberg + ARGONAS bare

┌─ Per-variant BUILDERS (build mechanism differs) ──────────────────────────┐
│  cix-installer        Cix Sky1   — d-i/debootstrap netinstall   [ACTIVE]   │
│  pi-gen               Raspberry Pi — pi-gen image                [ACTIVE]   │
│  jetson-installer     NVIDIA Jetson — flash/SDK                  [DEFERRED] │
└───────────────────────────────────────────────────────────────────────────┘

┌─ Shared USERLAND (consumed by every builder) ─────────────────────────────┐
│  distro-core   variant-agnostic post-install hooks + assets:              │
│                zeroclaw quadlet, embedkit, python311 runtime, desktop,    │
│                branding, ncz CLI, agent-stack, sysconfig                  │
└───────────────────────────────────────────────────────────────────────────┘

┌─ Per-variant KERNELS ─────────────────────────────────────────────────────┐
│  linux-cix · linux-rpi · linux-nvidia-tegra [tegra parked]                │
└───────────────────────────────────────────────────────────────────────────┘

┌─ BSP / Yocto (FROZEN — registered, maintainer-owned) ─────────────────────┐
│  meta-cix  ← DO NOT MOVE/RENAME      meta · meta-base (shared)            │
│  meta-tegra (maintainer-managed at layers.openembedded.org; parked)      │
└───────────────────────────────────────────────────────────────────────────┘

┌─ Cross-cutting ───────────────────────────────────────────────────────────┐
│  debs (apt packaging) · ncz-tools (zterm + ncz CLI)                       │
└───────────────────────────────────────────────────────────────────────────┘
```

### What lives in `distro-core` vs a builder

| Concern | distro-core (shared) | builder (per-variant) |
| --- | --- | --- |
| Agent stack (zeroclaw quadlet, ncz CLI, agent-env) | ✅ | — |
| NPU/AI runtime (embedkit, python3.11, models) | ✅ | — |
| Desktop (XFCE/LightDM, branding, wallpapers, plymouth) | ✅ | — |
| System config (network, ntp/hostname, ssh posture, diag acct) | ✅ | — |
| Build mechanism (ISO/image build scripts, preseed/pi-gen stages) | — | ✅ |
| Kernel + modules staging, `kernel-manifest`, bootloader entries | — | ✅ |
| Firmware blobs, DTBs, hardware quirks (e.g. Cix NPU/audio patches) | — | ✅ |

Consumption model: builders pull `distro-core` as a **git submodule** pinned to
a tag (simple, offline-friendly, matches the air-gapped ISO build). A `.deb`
packaging of `distro-core` is a future option once the apt repo matures.

---

## 3. The `distro` → `distro-core` migration

`ncz-os/distro` ("claw-family agentic distribution — OS, CLI, installer") is the
right conceptual home for the shared core, but today it is **stale and
diverged**:

- GitLab `nclawzero-rebase` @ `1f123c9` (+ `fix/wrapper-fixes-per-audit-…`)
- GitHub `nclawzero-rebase` @ `1874434a` — carries a **PII-scrub commit**
  (fleet LAN IPs → RFC1918, employer email → personal) that GitLab lacks.

**Reconcile-then-repurpose** (lowest risk, loses nothing):

1. **Reconcile divergence** — fast-forward/merge GitHub's PII-scrub commit into
   GitLab `distro` so the canonical forge has the strictly-newer history. Verify
   no other unique GitHub commits. Then force the mirrors to match GitLab.
2. **Rename** `distro` → `distro-core` on GitLab; update mirror remotes. (GitLab
   redirects the old path, so existing clones keep working.)
3. **Factor shared hooks** out of `cix-installer` into `distro-core`:
   - Move: `post-install/{20-desktop,30-agents,45-wallpaper-rotator,46-*,
     47-embedkit,50-brand, …}.sh`, `assets/{agent-stack,install_ncz_agents.sh,
     ncz-cli.sh, wallpapers, branding}`, `docs/{EMBEDKIT,MNEMOS-NPU,…}`.
   - Keep in `cix-installer`: ISO build (`build/`), `preseed/`, kernel manifest,
     `post-install/{12-sky1-firmware,25-cix-proprietary,70-bootloader,80-npu}.sh`,
     Cix kernel/DTB/firmware assets.
4. **Wire the submodule**: `cix-installer` adds `distro-core` as a submodule and
   `run-all.sh` sources both its own hooks and the shared ones in numeric order.
5. **pi-gen** later adopts the same `distro-core` submodule in a pi-gen stage.

---

## 4. Naming conventions (so future variants slot in)

| Kind | Pattern | Examples |
| --- | --- | --- |
| Kernel | `linux-<vendor|platform>` | `linux-cix`, `linux-rpi`, `linux-nvidia-tegra` |
| Yocto BSP | `meta-<vendor>` | `meta-cix` (registered) |
| Builder | `<platform>-installer` or upstream tool fork | `cix-installer`, `pi-gen`, `jetson-installer` |
| Shared userland | `distro-core` | — |
| Shared packaging | `debs` | — |
| Tooling | `ncz-tools` | — |

Variant status tags used in this org doc: **[ACTIVE] / [DEFERRED] / [PARKED]**.

---

## 5. Constraints & non-goals

- **`meta-cix` is frozen**: not moved/renamed. Its layers.openembedded.org VCS
  URL may be re-pointed by the maintainer to canonical GitLab, but that is out
  of band from these repo moves.
- **Jetson is deferred**: `linux-nvidia-tegra` stays; no `jetson-installer` or
  active `meta-tegra` work until a test system exists. `meta-tegra` registration
  is maintainer-managed at Yocto.
- **No history loss**: every move preserves git history (mirror reconcile before
  rename; `git mv` / `filter-repo` with history when factoring hooks).
- **Mirrors never lead**: if a mirror ever diverges (as `distro` did), reconcile
  into GitLab first, then hard-sync the mirror.

---

## 6. Phased execution checklist

- [ ] **P0 (this doc)** — land org plan in `cix-installer/docs/`.
- [ ] **P1 reconcile** — merge GitHub `distro` PII-scrub into GitLab; hard-sync mirrors.
- [ ] **P2 rename** — `distro` → `distro-core` on GitLab; fix mirror remotes.
- [ ] **P3 factor** — move shared hooks/assets/docs `cix-installer` → `distro-core` (history-preserving).
- [ ] **P4 wire** — `cix-installer` consumes `distro-core` submodule; `run-all.sh` merges hook order; build a verifying ISO (r113).
- [ ] **P5 mirror automation** — GitLab→GitHub/Codeberg push mirroring (CI or `git push --mirror` hook) so this never drifts again.
- [ ] **P6 pi-gen** — adopt `distro-core` submodule in a pi-gen stage.
- [ ] **(later) Jetson** — when test HW lands: `jetson-installer` + `meta-tegra` reactivation.
