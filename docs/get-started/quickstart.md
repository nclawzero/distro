---
title:
  page: "NemoClaw Quickstart: Install, Launch, and Run Your First Agent"
  nav: "Quickstart"
description:
  main: "Install NemoClaw, choose an agent runtime, launch a sandbox, and run your first agent prompt."
  agent: "Installs NemoClaw, helps choose OpenClaw, ZeroClaw, or Hermes, launches a sandbox, and runs the first agent prompt. Use when onboarding, installing, or launching a NemoClaw sandbox for the first time."
keywords: ["nemoclaw quickstart", "install nemoclaw openclaw zeroclaw hermes sandbox"]
topics: ["generative_ai", "ai_agents"]
tags: ["openclaw", "zeroclaw", "hermes", "openshell", "sandboxing", "inference_routing", "nemoclaw"]
content:
  type: get_started
  difficulty: technical_beginner
  audience: ["developer", "engineer"]
status: published
---

<!--
  SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
  SPDX-License-Identifier: Apache-2.0
-->

# Quickstart

:::{admonition} Alpha software
NemoClaw is in alpha, available as an early preview since March 16, 2026.
APIs, configuration schemas, and runtime behavior are subject to breaking changes between releases.
Do not use this software in production environments.
File issues and feedback through the GitHub repository as the project continues to stabilize.
:::

Follow these steps to get started with NemoClaw and your first sandboxed agent.

## Prerequisites

Before getting started, check the prerequisites to ensure you have the necessary software and hardware to run NemoClaw.

### Hardware

| Resource | Minimum        | Recommended      |
|----------|----------------|------------------|
| CPU      | 4 vCPU         | 4+ vCPU          |
| RAM      | 8 GB           | 16 GB            |
| Disk     | 20 GB free     | 40 GB free       |

The sandbox image is approximately 2.4 GB compressed. During image push, the Docker daemon, k3s, and the OpenShell gateway run alongside the export pipeline, which buffers decompressed layers in memory. On machines with less than 8 GB of RAM, this combined usage can trigger the OOM killer. If you cannot add memory, configuring at least 8 GB of swap can work around the issue at the cost of slower performance.

### Software

| Dependency | Version                          |
|------------|----------------------------------|
| Node.js    | 22.16 or later |
| npm        | 10 or later |
| Platform   | See [Platform Support](platform-support.md) |

:::{warning} OpenShell lifecycle
For NemoClaw-managed environments, use `nemoclaw onboard` when you need to create or recreate the OpenShell gateway or sandbox.
Avoid `openshell self-update`, `npm update -g openshell`, `openshell gateway start --recreate`, or `openshell sandbox create` directly unless you intend to manage OpenShell separately and then rerun `nemoclaw onboard`.
:::

### Container Runtimes

The following table lists tested platform and runtime combinations.
Availability is not limited to these entries, but untested configurations may have issues.

<!-- platform-matrix:begin -->
| OS | Container runtime | Status | Notes |
|----|-------------------|--------|-------|
| Linux | Docker | Tested | Primary tested path. |
| macOS (Apple Silicon) | Colima, Docker Desktop | Tested with limitations | Install Xcode Command Line Tools (`xcode-select --install`) and start the runtime before running the installer. |
| DGX Spark | Docker | Tested | Use the standard installer and `nemoclaw onboard`. |
| Windows WSL2 | Docker Desktop (WSL backend) | Tested with limitations | Requires WSL2 with Docker Desktop backend. |
<!-- platform-matrix:end -->

## Choose Your Agent

Before onboarding, choose the runtime that should run inside the sandbox.
For a full decision guide, see [Selecting an Agent](../agents/selecting-an-agent.md).

| Runtime | Choose when | Per-agent runbook |
|---------|-------------|-------------------|
| OpenClaw | You want the upstream NemoClaw assistant path, OpenClaw dashboard, device pairing, and OpenClaw plugins. | [OpenClaw](../agents/openclaw.md) |
| ZeroClaw | You want the primary `nclawzero/distro` Rust runtime, TOML config, OpenAI-compatible API, and edge-agentic provider routing model. | [ZeroClaw](../agents/zeroclaw.md) |
| Hermes | You want Hermes Agent from Nous Research inside the NemoClaw sandbox, with YAML plus `.env` config and an OpenAI-compatible API. | [Hermes](../agents/hermes.md) |

Each agent has its own gateway port and health probe:

| Runtime | Gateway port | Health probe |
|---------|--------------|--------------|
| OpenClaw | `18789` | `http://localhost:18789/` |
| ZeroClaw | `42617` | `http://localhost:42617/health` |
| Hermes | `8642` | `http://localhost:8642/health` |

## Install NemoClaw and Onboard an Agent

Download and run the installer script.
The script installs Node.js if it is not already present, then runs the guided onboard wizard to create a sandbox, configure inference, and apply security policies.
Where the CLI offers an agent selection flow, pick the runtime you chose above.
If your current build defaults to OpenClaw, use the per-agent runbooks for the adapter-specific build and health checks.

:::{note}
NemoClaw creates a fresh agent instance inside the sandbox during the onboarding process.
:::

```bash
curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash
```

If you use nvm or fnm to manage Node.js, the installer may not update your current shell's PATH.
If `nemoclaw` is not found after install, run `source ~/.bashrc` (or `source ~/.zshrc` for zsh) or open a new terminal.

:::{note}
The onboard flow builds the sandbox image with `NEMOCLAW_DISABLE_DEVICE_AUTH=1` so the dashboard is immediately usable during setup.
This is a build-time setting baked into the sandbox image, not a runtime knob.
If you export `NEMOCLAW_DISABLE_DEVICE_AUTH` after onboarding finishes, it has no effect on an existing sandbox.
:::

When the install completes, a summary confirms the running environment:

```text
──────────────────────────────────────────────────
Sandbox      my-assistant (Landlock + seccomp + netns)
Model        nvidia/nemotron-3-super-120b-a12b (NVIDIA Endpoints)
──────────────────────────────────────────────────
Run:         nemoclaw my-assistant connect
Status:      nemoclaw my-assistant status
Logs:        nemoclaw my-assistant logs --follow
──────────────────────────────────────────────────

[INFO]  === Installation complete ===
```

## Chat with the Agent

Connect to the sandbox, then chat with the agent through its runtime-specific interface.

```bash
nemoclaw my-assistant connect
```

For OpenClaw, open the terminal UI and start a chat:

```bash
openclaw tui
```

Alternatively, send a single message and print the response:

```bash
openclaw agent --agent main --local -m "hello" --session-id test
```

For ZeroClaw or Hermes, connect an OpenAI-compatible client to the runtime API:

| Runtime | API base URL |
|---------|--------------|
| ZeroClaw | `http://localhost:42617/v1` |
| Hermes | `http://localhost:8642/v1` |

Confirm the health endpoint first:

```bash
curl http://localhost:42617/health
curl http://localhost:8642/health
```

## Uninstall

To remove NemoClaw and all resources created during setup, run the uninstall script:

```bash
curl -fsSL https://raw.githubusercontent.com/NVIDIA/NemoClaw/refs/heads/main/uninstall.sh | bash
```

| Flag               | Effect                                              |
|--------------------|-----------------------------------------------------|
| `--yes`            | Skip the confirmation prompt.                       |
| `--keep-openshell` | Leave the `openshell` binary installed.              |
| `--delete-models`  | Also remove NemoClaw-pulled Ollama models.           |

For troubleshooting installation or onboarding issues, see the [Troubleshooting guide](../reference/troubleshooting.md).

## Next Steps

- [Switch inference providers](../inference/switch-inference-providers.md) to use a different model or endpoint.
- [Agent Runtimes](../agents/index.md) to compare OpenClaw, ZeroClaw, and Hermes.
- [Platform Support](platform-support.md) to check target platform and container runtime expectations.
- [Approve or deny network requests](../network-policy/approve-network-requests.md) when the agent tries to reach external hosts.
- [Customize the network policy](../network-policy/customize-network-policy.md) to pre-approve trusted domains.
- [Deploy to a remote GPU instance](../deployment/deploy-to-remote-gpu.md) for always-on operation.
- [Monitor sandbox activity](../monitoring/monitor-sandbox-activity.md) through the OpenShell TUI.

## Troubleshooting

If you run into issues during installation or onboarding, refer to the [Troubleshooting guide](../reference/troubleshooting.md) for common error messages and resolution steps.
