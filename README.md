> ## 📍 Canonical source: GitLab
> The authoritative source for this project lives on GitLab — always: **https://gitlab.com/ncz-os/distro-core**
>
> This GitHub repository is retained **only** to host release assets. Development, issues, and merge requests happen on GitLab.

---

# NCZ — Agentic Linux Distribution

> **🌐 Language:** English · [简体中文](README.zh-CN.md)
>
> **📚 Start here:** [AI/ML Stack Reference](https://gitlab.com/ncz-os/cix-installer/-/blob/main/docs/AI-ML-STACK.md) ([中文](https://gitlab.com/ncz-os/cix-installer/-/blob/main/docs/AI-ML-STACK.zh-CN.md)) · [How Did We Get Here — engineering post-mortem](https://gitlab.com/ncz-os/cix-installer/-/blob/main/docs/HOW-DID-WE-GET-HERE.md) ([中文](https://gitlab.com/ncz-os/cix-installer/-/blob/main/docs/HOW-DID-WE-GET-HERE.zh-CN.md)) · [NCZ-OS Organization](docs/NCZ-OS-ORGANIZATION.md)

**NCZ Distribution Core** is the heart of NCZ: an **agentic Linux distribution
for Arm and Intel systems**, and the home of **MNEMOS**, the agentic memory
system.

NCZ ships a complete, autonomous-agent-ready operating system — a hardened
Ubuntu base, an always-on agent stack, on-device AI (NPU / GPU / CPU
embeddings), and MNEMOS memory — that boots and runs on edge boards, desktops,
and servers across both **Arm** (e.g. CIX Sky1, Raspberry Pi) and **Intel /
x86-64** hardware.

This repository is the **shared, hardware-agnostic core** of that distribution:
the userland, agent stack, AI runtime, desktop, branding, and CLI that every
hardware variant builds on. Platform-specific *builders* consume this core and
add only the bits unique to their hardware (kernel, firmware, bootloader,
device trees).

---

## What's in the box

- **MNEMOS** — the agentic memory operating system. Production-grade memory for
  agents, interoperating with every major framework via MCP, an
  OpenAI-compatible gateway, and native `/v1/*` REST. NCZ is its home.
  → [`ncz-os/mnemos`](https://github.com/ncz-os/mnemos)
- **Agent stack** — ZeroClaw runs out of the box as a Podman quadlet; OpenClaw
  and Hermes are operator opt-in via the `ncz` CLI.
- **On-device AI** — automatic embeddings across NPU / GPU / CPU via
  `mnemos-embedkit`, with the same API on every silicon target.
- **Desktop** — a polished XFCE environment with NCZ branding (the *Reinhardt*
  desktop variant), or a headless server profile (*Magnetar*).
- **`ncz` CLI** — operator tooling for the agent stack and fleet.

## How it's organized

```
NCZ Distribution Core  (this repo — shared userland)
        │ consumed by
        ▼
Per-variant BUILDERS (build mechanism differs per platform)
  cix-installer     CIX Sky1 (Arm)        — d-i / debootstrap netinstall
  pi-gen            Raspberry Pi (Arm)    — pi-gen image
  (x86-64 builder)  Intel / AMD desktops  — planned

Per-variant KERNELS:  linux-cix · linux-rpi · …
BSP / Yocto:          meta-cix (registered BSP layer) · meta · meta-base
Packaging / tooling:  debs · ncz-tools
```

The core is consumed as a pinned git submodule (offline-friendly for air-gapped
image builds); a `.deb` packaging is a future option.

See [`docs/`](docs/) for the full organization and migration plan.

## Canonical source & mirrors

GitLab `ncz-os/*` is the **canonical source of truth**. GitHub and Codeberg are
**mirrors** kept in lockstep — never push to a mirror as the lead.

- GitLab (canonical): https://gitlab.com/ncz-os/distro-core
- GitHub (mirror): https://github.com/ncz-os/distro-core
- Codeberg (mirror): https://codeberg.org/ncz-os/distro-core

## Supported hardware (and what's actually tested)

> Vendor-neutral *by design* ≠ tested everywhere. To date the distribution
> has only been validated on **one** board. Testers and donated hardware are
> the fastest way to expand this list.

| Architecture | Target | Status |
| --- | --- | --- |
| Arm (aarch64) | **CIX Sky1 — Minisforum MS-R1** (32 GB / 64 GB) | ✅ **Tested** — the only validated platform |
| Arm (aarch64) | **CIX Sky1 — Radxa Orion O6 / O6N** | ❌ **Untested — testers wanted, board needed** (different board, same SoC) |
| Arm (aarch64) | **CIX Sky1 — Framework add-in board** | ❌ Untested — no hardware in hand |
| Arm (aarch64) | **CIX Sky1 — Orange Pi (Cix variants)** | ❌ Untested — no hardware in hand |
| Arm (aarch64) | Raspberry Pi | 🚧 Builder exists (pi-gen); not yet validated |
| Intel / AMD (x86-64) | Desktops / servers | 🗺️ Planned |

**If you can help:** an O6 (or any non-MS-R1 Cix board) in our hands, or a
community tester filing issues, directly unblocks support. Radxa, Framework,
Orange Pi — we'd love a board.

## License

Apache-2.0. See [`LICENSE`](LICENSE).
