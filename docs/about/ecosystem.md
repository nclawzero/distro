---
title:
  page: "NemoClaw Ecosystem: Claw-Family Agents, Stack Placement, and OpenShell"
  nav: "Ecosystem"
description:
  main: "How OpenClaw, ZeroClaw, Hermes, OpenShell, and NemoClaw fit together, where NemoClaw sits, and when to use the reference integration versus OpenShell alone."
  agent: "Explains how OpenClaw, ZeroClaw, Hermes, OpenShell, and NemoClaw form the ecosystem, NemoClaw's position in the stack, what NemoClaw adds beyond the community sandbox, and when to prefer NemoClaw versus integrating OpenShell directly. Use when users ask about the relationship between claw-family agents, OpenShell, and NemoClaw, or when to use NemoClaw versus OpenShell."
keywords: ["nemoclaw ecosystem", "openclaw zeroclaw hermes openshell", "nemoclaw vs openshell", "sandboxed agents"]
topics: ["generative_ai", "ai_agents"]
tags: ["openclaw", "zeroclaw", "hermes", "openshell", "sandboxing", "blueprints", "inference_routing"]
content:
  type: concept
  difficulty: technical_beginner
  audience: ["developer", "engineer"]
status: published
---

<!--
  SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
  SPDX-License-Identifier: Apache-2.0
-->

# Ecosystem

NemoClaw provides onboarding, lifecycle management, and agent runtime operations within OpenShell containers.

This page describes how the ecosystem is formed across projects, where NemoClaw sits relative to [OpenShell](https://github.com/NVIDIA/OpenShell) and the claw-family agent runtimes, and how to choose between NemoClaw and OpenShell.

## How the Stack Fits Together

Three layers usually appear together in a NemoClaw deployment, each with a distinct scope:

| Project | Scope |
|---------|--------|
| Claw-family agent | The tenant inside the sandbox: OpenClaw, ZeroClaw, or Hermes. It owns agent behavior, config format, API surface, and mutable agent state. |
| [OpenShell](https://github.com/NVIDIA/OpenShell) | The execution environment: sandbox lifecycle, network, filesystem, and process policy, inference routing, and the operator-facing `openshell` CLI for those primitives. |
| NemoClaw | The reference stack that implements the integration on the host: `nemoclaw` CLI and plugin, versioned blueprint, per-agent adapters, channel messaging configured for OpenShell-managed delivery, and state migration helpers so agents run inside OpenShell in a documented, repeatable way. |

NemoClaw sits above OpenShell in the operator workflow.
It drives OpenShell APIs and CLI to create and configure the sandbox that runs the selected agent.
Models and endpoints sit behind OpenShell's inference routing.
NemoClaw onboarding wires provider choice into that routing.

```{mermaid}
flowchart TB
    NC["NemoClaw<br/>CLI, plugin, blueprint"]
    OS["OpenShell<br/>Gateway, policy, inference routing"]
    OC["Agent tenant<br/>OpenClaw · ZeroClaw · Hermes"]

    NC -->|orchestrates| OS
    OS -->|isolates and runs| OC

    classDef nv fill:#76b900,stroke:#333,color:#fff
    classDef nvLight fill:#e6f2cc,stroke:#76b900,color:#1a1a1a
    classDef nvDark fill:#333,stroke:#76b900,color:#fff

    class NC nv
    class OS nv
    class OC nvDark

    linkStyle 0 stroke:#76b900,stroke-width:2px
    linkStyle 1 stroke:#76b900,stroke-width:2px
```

## The Claw Family

The public `nclawzero/distro` tree carries three agent adapters.
They are siblings from the sandbox platform's perspective, not nested layers.

| Agent | Role | Use when |
|-------|------|----------|
| [OpenClaw](../agents/openclaw.md) | Upstream NemoClaw baseline and always-on assistant runtime with dashboard and device pairing. | You want OpenClaw behavior, OpenClaw plugins, and the original NemoClaw assistant flow. |
| [ZeroClaw](../agents/zeroclaw.md) | Primary `nclawzero/distro` runtime, implemented as a Rust binary with TOML config and OpenAI-compatible API. | You want the ZeroClaw edge/runtime path, no browser-pairing flow, and the README provider routing model. |
| [Hermes](../agents/hermes.md) | Nous Research Hermes Agent integration with Python, YAML plus `.env`, writable learning-loop state, and OpenAI-compatible API. | You want to run Hermes inside NemoClaw's sandbox instead of as a standalone process. |

For a decision guide, see [Selecting an Agent](../agents/selecting-an-agent.md).

## NemoClaw Path versus OpenShell Path

Both paths assume OpenShell can sandbox a workload.
The difference is who owns the integration work.

| Path | What it means |
|------|---------------|
| **NemoClaw path** | You adopt the reference stack. NemoClaw's blueprint and agent adapters encode hardened images, default policies, and orchestration so `nemoclaw onboard` can stand up a known-good agent-on-OpenShell setup with less custom glue. |
| **OpenShell path** | You use OpenShell as the platform and supply your own container, agent install steps, policy YAML, provider setup, and any host bridges. OpenShell stays the sandbox and policy engine; nothing requires NemoClaw's blueprint or CLI. |

## What NemoClaw Adds Beyond the OpenShell Community Sandbox

OpenShell ships a community sandbox for OpenClaw.
Running `openshell sandbox create --from openclaw` pulls that package, builds the image, applies the bundled policy, and starts a working sandbox.
This is a valid path, and it produces a running OpenClaw environment with OpenShell isolation.

NemoClaw builds on that foundation with additional security hardening, automation, lifecycle tooling, and multi-agent adapter structure.
The following table compares the two paths.

| Capability | `openshell sandbox create --from openclaw` | `nemoclaw onboard` |
|---|---|---|
| Sandbox isolation | Yes. OpenShell applies seccomp filters, Landlock filesystem restrictions, privilege dropping, network namespace isolation, and no-new-privileges enforcement. The community sandbox bundles its own policy tailored for OpenClaw. | Yes. NemoClaw applies these through the blueprint and layers a more restrictive policy on top (see rows below). |
| Credential handling | OpenShell's provider system replaces real credentials with placeholder tokens in the sandbox environment. The L7 proxy resolves placeholders to real values at egress. You create providers manually with `openshell provider create`. | NemoClaw creates OpenShell providers automatically during onboarding. It also filters sensitive host environment variables (provider API keys, `DISCORD_BOT_TOKEN`, `SLACK_BOT_TOKEN`, `TELEGRAM_BOT_TOKEN`) from the sandbox creation command to prevent accidental leakage through build args. |
| Image hardening | The community image includes standard system tools for general-purpose use. | NemoClaw strips build toolchains (`gcc`, `g++`, `make`) and network probes (`netcat`) from the runtime image to reduce attack surface. |
| Filesystem policy | The community sandbox bundles a policy for OpenClaw. | NemoClaw defines a more restrictive read-only and read-write layout. The agent's home directory (`/sandbox`) is read-only. Gateway config (`/sandbox/.openclaw`) is immutable. Only specific data paths (`/sandbox/.openclaw-data`, `/sandbox/.nemoclaw`, `/tmp`) are writable. This prevents the agent from writing and executing scripts, modifying its own environment, or staging data for exfiltration. |
| Inference setup | The community sandbox includes an `openclaw-start` script that runs OpenClaw's onboarding wizard inside the sandbox. You can also create providers and configure OpenShell inference routing manually from the host. | NemoClaw's onboarding wizard validates your credential from the host, lets you select a supported provider (NVIDIA Endpoints, OpenAI-compatible providers, Google, Ollama, and compatible local endpoints), and configures OpenShell's inference routing automatically. Credentials stay on the host and are delivered through OpenShell's provider system. |
| Channel messaging | OpenShell provides the credential provider system and L7 proxy that delivers channel tokens securely (including path-based resolution for Telegram's `/bot<token>/` URL pattern). You create providers and configure OpenClaw's channel settings manually. | NemoClaw automates channel setup during onboarding: it collects bot tokens, registers them as OpenShell providers, and bakes OpenClaw channel config with placeholder tokens that OpenShell's proxy resolves at egress. No separate bridge process runs on the host. |
| Blueprint versioning | No blueprint. The community sandbox uses whatever image version is currently published. | NemoClaw downloads the blueprint artifact, checks version compatibility, and verifies its digest before applying. Running `nemoclaw onboard` on different machines produces the same sandbox. |
| State migration | Not included. | NemoClaw migrates agent state across machines with credential stripping and integrity verification. |
| Process count limits | OpenShell applies seccomp and privilege dropping. You set process count limits manually with `--ulimit` or orchestrator config. | NemoClaw applies `ulimit -u 512` in the container entrypoint to cap the process count and mitigate fork-bomb attacks, on top of OpenShell's seccomp and privilege dropping. |

## When to Use Which

Use the following table to decide when to use NemoClaw versus OpenShell.

| Situation | Prefer |
|-----------|--------|
| You want OpenClaw, ZeroClaw, or Hermes with minimal assembly, reference defaults, and the documented install and onboard flow. | NemoClaw |
| You need maximum flexibility for custom images, a layout that does not match the NemoClaw blueprint, or a workload outside this reference stack. | OpenShell with your own integration |
| You are standardizing on a reference integration for claw-family agents with policy and inference routing. | NemoClaw |
| You are building internal platform abstractions where the NemoClaw CLI or blueprint is not the right fit. | OpenShell (and your orchestration) |

## Related topics

- [Overview](overview.md) contains what NemoClaw is, capabilities, benefits, platform support, and use cases.
- [Agent Runtimes](../agents/index.md) compares OpenClaw, ZeroClaw, and Hermes.
- [How It Works](how-it-works.md) describes how NemoClaw runs, plugin, blueprint, sandbox creation, routing, protection layers.
- [Architecture](../reference/architecture.md) shows the repository structure and technical diagrams.
