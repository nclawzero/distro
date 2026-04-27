---
title:
  page: "NemoClaw Agent Runtimes: OpenClaw, ZeroClaw, and Hermes"
  nav: "Agent Runtimes"
description:
  main: "Overview of the claw-family agent runtimes that NemoClaw can run inside OpenShell sandboxes: OpenClaw, ZeroClaw, and Hermes."
  agent: "Compares OpenClaw, ZeroClaw, and Hermes as sandboxed NemoClaw tenants, including language, config format, gateway port, health probe, phone-home endpoints, API surface, and selection fit. Use when choosing which agent runtime to run inside NemoClaw."
keywords: ["nemoclaw agents", "openclaw zeroclaw hermes", "openshell sandbox agent runtimes"]
topics: ["generative_ai", "ai_agents"]
tags: ["openclaw", "zeroclaw", "hermes", "openshell", "sandboxing"]
content:
  type: concept
  difficulty: technical_beginner
  audience: ["developer", "engineer"]
status: published
---

<!--
  SPDX-FileCopyrightText: Copyright (c) 2026 Jason Perlow. All rights reserved.
  SPDX-License-Identifier: Apache-2.0
-->

# Agent Runtimes

NemoClaw is the sandbox integration layer for claw-family agents.
The public tree currently carries three sibling agent adapters under `agents/`: OpenClaw, ZeroClaw, and Hermes.
Each adapter defines the tenant contract that OpenShell needs: manifest metadata, filesystem and network policy additions, image build instructions, and an entrypoint that starts the agent safely inside the sandbox.

OpenClaw remains the upstream NemoClaw baseline.
ZeroClaw is the primary runtime for `nclawzero/distro`.
Hermes is available as a Python-based Nous Research integration with an OpenAI-compatible API surface.

## Runtime Matrix

| Runtime | Language | Config format | Gateway port | Health probe | Phone-home endpoints | API surface | Use-case fit | Best when |
|---------|----------|---------------|--------------|--------------|----------------------|-------------|--------------|-----------|
| [OpenClaw](openclaw.md) | Node/TypeScript | JSON (`openclaw.json`) | `18789` | `GET http://localhost:18789/` | OpenClaw and ClawHub (`openclaw.ai`, `docs.openclaw.ai`, `clawhub.ai`) | OpenClaw gateway and dashboard | Always-on assistants, browser dashboard, OpenClaw plugin ecosystem | You want the upstream NemoClaw path, OpenClaw device pairing, and the existing OpenClaw app-layer controls. |
| [ZeroClaw](zeroclaw.md) | Rust | TOML (`config.toml`) | `42617` | `GET http://localhost:42617/health` | Public adapter lists ZeroClaw Labs endpoints (`zeroclaw-labs.com`, `api.zeroclaw-labs.com`) | OpenAI-compatible `/v1/*` | Edge agentic runtime, smaller binary footprint, OpenAI-compatible frontend integration | You want the primary `nclawzero/distro` runtime, Rust deployment, no browser-pairing flow, and the 27-route provider model described in the README. |
| [Hermes](hermes.md) | Python | YAML plus `.env` (`config.yaml`, `.env`) | `8642` public, `18642` internal | `GET http://localhost:8642/health` | Nous Research (`nousresearch.com`, `hermes-agent.nousresearch.com`, `api.nousresearch.com`) | OpenAI-compatible `/v1/*` | Self-improving agent loop, Hermes skills/plugins, OpenAI-compatible frontend integration | You want to evaluate Hermes Agent inside the same NemoClaw/OpenShell security boundary instead of running it as a standalone Python agent. |

:::{note}
The ZeroClaw row reflects the public repository adapter.
If a private fleet policy uses `nclawzero-internal` endpoints instead of the public ZeroClaw Labs hosts, update the manifest and policy together so the docs and runtime policy stay aligned.
:::

## Adapter Files

Each runtime follows the same integration shape, even where individual files still live in legacy locations for backward compatibility.

| Runtime | Manifest | Policy | Entrypoint | Image |
|---------|----------|--------|------------|-------|
| OpenClaw | `agents/openclaw/manifest.yaml` | `nemoclaw-blueprint/policies/openclaw-sandbox.yaml` | `scripts/nemoclaw-start.sh` | `Dockerfile`, `Dockerfile.base` |
| ZeroClaw | `agents/zeroclaw/manifest.yaml` | `agents/zeroclaw/policy-additions.yaml` | `agents/zeroclaw/start.sh` | `agents/zeroclaw/Dockerfile`, `agents/zeroclaw/Dockerfile.base` |
| Hermes | `agents/hermes/manifest.yaml` | `agents/hermes/policy-additions.yaml` | `agents/hermes/start.sh` | `agents/hermes/Dockerfile`, `agents/hermes/Dockerfile.base` |

## Selection

Use [Selecting an Agent](selecting-an-agent.md) when you need a decision path.
Use the per-agent runbooks when you already know the runtime:

```{toctree}
:maxdepth: 1

Selecting an Agent <selecting-an-agent>
OpenClaw <openclaw>
ZeroClaw <zeroclaw>
Hermes <hermes>
```
