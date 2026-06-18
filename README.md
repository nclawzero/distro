# NCZ — Agentic Linux Distribution

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

## Supported hardware

| Architecture | Targets | Status |
| --- | --- | --- |
| Arm (aarch64) | CIX Sky1 (Minisforum MS-R1) | Active |
| Arm (aarch64) | Raspberry Pi | Active |
| Intel / AMD (x86-64) | Desktops / servers | Planned |

## License

Apache-2.0. See [`LICENSE`](LICENSE).
