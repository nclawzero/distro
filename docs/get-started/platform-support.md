---
title:
  page: "NemoClaw Platform Support"
  nav: "Platform Support"
description:
  main: "Cross-platform support matrix for running NemoClaw and nclawzero agent sandboxes across Raspberry Pi, arm64 SBCs, x86 Linux, macOS container runtimes, Cix Sky1 systems, Intel N-series SBCs, and Jetson."
  agent: "Lists supported, expected, coming, and unsupported platforms for NemoClaw and nclawzero agent sandboxes, including container runtime expectations and platform-specific install notes. Use when checking whether a target platform can run OpenClaw, ZeroClaw, or Hermes inside NemoClaw."
keywords: ["nemoclaw platform support", "nclawzero raspberry pi", "openshell arm64 x86 macos"]
topics: ["generative_ai", "ai_agents", "deployment"]
tags: ["platform_support", "raspberry_pi", "arm64", "x86", "macos", "podman", "docker"]
content:
  type: reference
  difficulty: technical_beginner
  audience: ["developer", "engineer"]
status: published
---

<!--
  SPDX-FileCopyrightText: Copyright (c) 2026 Jason Perlow. All rights reserved.
  SPDX-License-Identifier: Apache-2.0
-->

# Platform Support

NemoClaw targets Linux container sandboxes first.
The `nclawzero/distro` tree also tracks edge and SBC targets where ZeroClaw is the primary runtime.
Platform status below reflects the public repository state and the fleet policy described for this effort.

## Support Matrix

| Platform | Status | Container runtime | Notes |
|----------|--------|-------------------|-------|
| Raspberry Pi 4.x | Validated Pi family | Podman per fleet runtime policy | Use 64-bit Raspberry Pi OS or another arm64 Linux image. Keep swap available for image builds on low-memory boards. |
| Raspberry Pi Zero 2 W | Validated Pi family | Podman per fleet runtime policy | Memory-constrained. Prefer prebuilt images or lightweight ZeroClaw paths; image builds can be slow. |
| Raspberry Pi 5 | Validated Pi family | Podman per fleet runtime policy | Best Pi-class target for local image builds and persistent edge testing. |
| Pi-adjacent arm64 SBCs: Orange Pi, Banana Pi, Radxa Rock, Khadas, NanoPi, Odroid | Expected to work | Podman per fleet runtime policy | Same productization ocean as Pi: arm64 Linux, cgroup and user namespace behavior, kernel Landlock support, and container runtime packaging are the main variables. Validate policy enforcement before relying on the sandbox boundary. |
| x86 Linux workstation with NVIDIA dGPU | Active production daily use | Docker | Primary high-capacity path for local builds, provider harness work, local inference, and GPU-backed testing. |
| macOS with Docker or OrbStack | Supported with container-runtime limits | Docker Desktop or OrbStack | Runs Linux containers through the runtime VM. Start the runtime first. Filesystem, networking, and port-forward behavior can differ from native Linux. |
| Cix Sky1 systems: Minisforum MS-R1, Radxa Orion O6 | Coming, validation pending | Podman per fleet runtime policy | Expected to work as arm64 Linux targets. Treat as pending until image builds, OpenShell networking, Landlock behavior, and per-agent health probes are validated. |
| Intel N-series x86 SBCs: ZimaBoard 2 and similar | Coming, expected to work | Docker unless fleet policy sets Podman | Expected to behave like small x86 Linux workstations. Watch RAM, disk, and thermal limits during image builds. |
| Jetson public tree | Not supported | Not supported in public tree | Jetson support has productization issues and is private-branch only. Do not treat Jetson as supported by this repository. |

## Runtime Notes

Podman is the expected runtime for Pi-family and Cix-class fleet targets.
Docker is the expected runtime on x86 Linux workstations.
macOS uses a Linux container VM through Docker Desktop or OrbStack.

Before running a sandbox on any target, verify:

- The kernel and runtime support the OpenShell isolation features used by NemoClaw.
- The agent image exists for the target architecture or can be built there.
- The target has enough memory and disk for image build and sandbox runtime.
- The gateway port for the selected agent is forwarded: `18789` for OpenClaw, `42617` for ZeroClaw, `8642` for Hermes.
- The expected health probe succeeds after startup.

## Agent Fit by Platform

| Platform class | Preferred runtime | Reason |
|----------------|-------------------|--------|
| Low-memory arm64 edge boards | ZeroClaw | Rust binary, TOML config, and OpenAI-compatible API are a better match for constrained devices. |
| x86 Linux workstation with dGPU | ZeroClaw, OpenClaw, or Hermes | Enough capacity for all three runtimes, local inference, and harness work. |
| macOS runtime VM | ZeroClaw or Hermes for API testing; OpenClaw for dashboard testing | Useful for development and UI/API checks, but final policy validation should happen on Linux. |
| Research comparison sandbox | Multiple adjacent sandboxes | Run each agent in its own sandbox so policies, ports, and mutable state stay isolated. |

For runtime selection, see [Selecting an Agent](../agents/selecting-an-agent.md).
