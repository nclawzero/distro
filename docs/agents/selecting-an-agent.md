---
title:
  page: "Selecting a NemoClaw Agent Runtime"
  nav: "Selecting an Agent"
description:
  main: "Choose between OpenClaw, ZeroClaw, and Hermes for a NemoClaw-managed OpenShell sandbox."
  agent: "Decision guide for selecting OpenClaw, ZeroClaw, or Hermes as a NemoClaw sandbox tenant. Use when matching agent runtime to use case, deployment constraints, API shape, and multi-agent deployment patterns."
keywords: ["select nemoclaw agent", "openclaw vs zeroclaw vs hermes", "claw family agents"]
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

# Selecting an Agent

Choose the agent runtime based on the behavior you need inside the sandbox.
NemoClaw and OpenShell provide the sandbox boundary; OpenClaw, ZeroClaw, and Hermes provide different tenant behavior inside that boundary.

## Quick Decision

| Need | Choose |
|------|--------|
| Upstream NemoClaw behavior, OpenClaw dashboard, browser device pairing, OpenClaw plugins, and always-on assistant workflows. | [OpenClaw](openclaw.md) |
| Primary `nclawzero/distro` runtime, Rust binary deployment, OpenAI-compatible API, edge or embedded fit, and the README's 27-route provider harness model. | [ZeroClaw](zeroclaw.md) |
| Nous Research Hermes Agent, self-improving learning loop evaluation, Python skill/plugin ecosystem, and OpenAI-compatible frontend access. | [Hermes](hermes.md) |

## Use OpenClaw When

OpenClaw is best when the deployment is centered on the upstream NemoClaw assistant model.
It provides the OpenClaw gateway, dashboard, OpenClaw plugin ecosystem, browser device pairing, and the application-layer OpenClaw controls documented in [OpenClaw Controls](../security/openclaw-controls.md).

Prefer OpenClaw for:

- Always-on assistants with an OpenClaw dashboard.
- Teams that already use OpenClaw configuration and plugins.
- Deployments where device pairing is part of the expected access-control flow.
- Validating upstream NemoClaw behavior against OpenShell policies.

## Use ZeroClaw When

ZeroClaw is the primary runtime for this repository.
It is a Rust binary with TOML config and an OpenAI-compatible API on port `42617`.
It is a better fit when the deployment values smaller runtime shape, direct OpenAI-compatible frontend integration, and the `nclawzero` provider routing model.

Prefer ZeroClaw for:

- Edge agentic deployments and resource-constrained Linux targets.
- OpenAI-compatible clients that expect `/v1/*` endpoints.
- Testing the provider harness and failover routes described in the README.
- Sandboxes where OpenClaw browser pairing is not desired.

## Use Hermes When

Hermes is best when the goal is to run the Nous Research Hermes Agent in the same NemoClaw security posture used for the claw-family runtimes.
It is Python-based, uses YAML plus `.env`, exposes an OpenAI-compatible API on port `8642`, and maintains Hermes state under `.hermes-data`.

Prefer Hermes for:

- Evaluating the Hermes self-improving agent loop under OpenShell controls.
- Using Hermes-specific skills, plugins, and Nous Research endpoints.
- Connecting OpenAI-compatible frontends such as Open WebUI or LobeChat to Hermes.
- Comparing Hermes behavior to OpenClaw and ZeroClaw in adjacent sandboxes.

## Multi-Agent Deployments

Run multiple agents as adjacent sandboxes when each agent needs a different policy, API surface, or runtime language.
Do not place multiple unrelated agent runtimes into one sandbox unless they are designed to share one config and policy boundary.

Examples:

| Pattern | Why it works |
|---------|--------------|
| OpenClaw assistant plus ZeroClaw edge worker | OpenClaw handles dashboard-centric assistant work while ZeroClaw serves an OpenAI-compatible edge API on a separate port and policy. |
| ZeroClaw production sandbox plus Hermes evaluation sandbox | ZeroClaw remains the primary runtime while Hermes is tested against the same OpenShell controls without sharing mutable state. |
| OpenClaw baseline plus Hermes research sandbox | Maintainers can compare OpenClaw and Hermes behavior while each tenant keeps its own manifest, network policy, config format, and entrypoint. |

Each sandbox should keep its own:

- Agent manifest.
- Filesystem policy.
- Network allowlist.
- Gateway port.
- Config directory.
- Writable state directory.

## Sanity Checks

Before creating a sandbox, confirm:

| Question | Why it matters |
|----------|----------------|
| Which API surface do clients expect? | OpenClaw uses the OpenClaw gateway and dashboard; ZeroClaw and Hermes expose OpenAI-compatible `/v1` APIs. |
| Which package registry is required? | OpenClaw uses npm, Hermes uses PyPI, and ZeroClaw's runtime does not require PyPI. |
| Which phone-home endpoints are acceptable? | OpenClaw uses OpenClaw and ClawHub hosts, ZeroClaw uses its public ZeroClaw Labs hosts in this tree, and Hermes uses Nous Research hosts. |
| Does the agent need browser pairing? | OpenClaw supports it; ZeroClaw and Hermes disable OpenClaw-style pairing in these adapters. |
| Which platform is targeted? | Check [Platform Support](../get-started/platform-support.md) before selecting an image and container runtime. |
