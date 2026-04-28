---
title:
  page: "NemoClaw Architecture: Plugin, Blueprint, and Sandbox Structure"
  nav: "Architecture"
description:
  main: "Learn how NemoClaw combines a lightweight CLI plugin, versioned blueprint, and per-agent adapters to move OpenClaw, ZeroClaw, and Hermes into controlled sandboxes."
  agent: "Describes how NemoClaw combines a CLI plugin, versioned blueprint, and per-agent adapters to move OpenClaw, ZeroClaw, and Hermes into controlled sandboxes. Use when looking up NemoClaw architecture, plugin structure, blueprint design, or multi-agent sandbox integration."
keywords: ["nemoclaw architecture", "nemoclaw plugin blueprint structure", "openclaw zeroclaw hermes agents"]
topics: ["generative_ai", "ai_agents"]
tags: ["openclaw", "zeroclaw", "hermes", "openshell", "sandboxing", "blueprints", "inference_routing"]
content:
  type: reference
  difficulty: intermediate
  audience: ["developer", "engineer"]
status: published
---

<!--
  SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
  SPDX-License-Identifier: Apache-2.0
-->

# Architecture

NemoClaw has three main architectural layers: a TypeScript CLI/plugin layer, a versioned blueprint that orchestrates OpenShell resources, and per-agent adapters for the runtime that runs inside the sandbox.

## System Overview

NVIDIA OpenShell is a general-purpose agent runtime. It provides sandbox containers, a credential-storing gateway, inference proxying, and policy enforcement, but has no opinions about what runs inside. NemoClaw is an opinionated reference stack built on OpenShell that handles what goes in the sandbox and makes the setup accessible.

```{mermaid}
graph LR
    classDef nemoclaw fill:#76b900,stroke:#5a8f00,color:#fff,stroke-width:2px,font-weight:bold
    classDef openshell fill:#1a1a1a,stroke:#1a1a1a,color:#fff,stroke-width:2px,font-weight:bold
    classDef sandbox fill:#444,stroke:#76b900,color:#fff,stroke-width:2px,font-weight:bold
    classDef agent fill:#f5f5f5,stroke:#e0e0e0,color:#1a1a1a,stroke-width:1px
    classDef external fill:#f5f5f5,stroke:#e0e0e0,color:#1a1a1a,stroke-width:1px
    classDef user fill:#fff,stroke:#76b900,color:#1a1a1a,stroke-width:2px,font-weight:bold

    USER(["👤 User"]):::user

    subgraph EXTERNAL["External Services"]
        INFERENCE["Inference Provider<br/><small>NVIDIA Endpoints · OpenAI-compatible<br/>Together · Groq · Ollama · vLLM</small>"]:::external
        MSGAPI["Messaging Platforms<br/><small>Telegram · Discord · Slack</small>"]:::external
        INTERNET["Internet<br/><small>PyPI · npm · GitHub · APIs</small>"]:::external
    end

    subgraph HOST["Host Machine"]

        subgraph NEMOCLAW["NemoClaw"]
            direction TB
            NCLI["CLI + Onboarding<br/><small>Guided setup · provider selection<br/>credential validation · deploy</small>"]:::nemoclaw
            BP["Blueprint<br/><small>Hardened Dockerfile<br/>Network policies · Presets<br/>Security configuration</small>"]:::nemoclaw
            MIGRATE["State Management<br/><small>Migration snapshots<br/>Credential stripping<br/>Integrity verification</small>"]:::nemoclaw
        end

        subgraph OPENSHELL["OpenShell"]
            direction TB
            GW["Gateway<br/><small>Credential store<br/>Inference proxy<br/>Policy engine<br/>Device auth</small>"]:::openshell
            OSCLI["openshell CLI<br/><small>provider · sandbox<br/>gateway · policy</small>"]:::openshell
            CHMSG["Channel messaging<br/><small>OpenShell-managed<br/>Telegram · Discord · Slack</small>"]:::openshell

            subgraph SANDBOX["Sandbox Container 🔒"]
                direction TB
                AGENT["Agent tenant<br/><small>OpenClaw · ZeroClaw · Hermes</small>"]:::agent
                PLUG["Adapter<br/><small>manifest · policy · entrypoint</small>"]:::sandbox
            end
        end
    end

    USER -->|"nemoclaw onboard<br/>nemoclaw connect"| NCLI
    USER -->|"Chat messages"| MSGAPI

    NCLI -->|"Orchestrates"| OSCLI
    BP -->|"Defines sandbox<br/>shape + policies"| SANDBOX
    MIGRATE -->|"Safe state<br/>transfer"| SANDBOX

    AGENT -->|"Inference requests<br/><small>no credentials</small>"| GW
    GW -->|"Proxied with<br/>credential injected"| INFERENCE

    MSGAPI -->|"Platform APIs"| CHMSG
    CHMSG -->|"Deliver to agent"| AGENT

    AGENT -.->|"Policy-gated"| INTERNET
    GW -.->|"Enforced by<br/>gateway"| INTERNET
```

## NemoClaw Plugin

The plugin is a thin TypeScript package that registers an inference provider and the `/nemoclaw` slash command.
It runs in-process with the OpenClaw gateway inside the sandbox.

```text
nemoclaw/
├── src/
│   ├── index.ts                    Plugin entry: registers all commands
│   ├── cli.ts                      Commander.js subcommand wiring
│   ├── commands/
│   │   ├── launch.ts               Fresh install into OpenShell
│   │   ├── connect.ts              Interactive shell into sandbox
│   │   ├── status.ts               Blueprint run state + sandbox health
│   │   ├── logs.ts                 Stream blueprint and sandbox logs
│   │   └── slash.ts                /nemoclaw chat command handler
│   └── blueprint/
│       ├── resolve.ts              Version resolution, cache management
│       ├── fetch.ts                Download blueprint from OCI registry
│       ├── verify.ts               Digest verification, compatibility checks
│       ├── exec.ts                 Subprocess execution of blueprint runner
│       └── state.ts                Persistent state (run IDs)
├── openclaw.plugin.json            Plugin manifest
└── package.json                    Commands declared under openclaw.extensions
```

## NemoClaw Blueprint

The blueprint is a versioned Python artifact with its own release stream.
The plugin resolves, verifies, and executes the blueprint as a subprocess.
The blueprint drives all interactions with the OpenShell CLI.

```text
nemoclaw-blueprint/
├── blueprint.yaml                  Manifest: version, profiles, compatibility
├── policies/
│   └── openclaw-sandbox.yaml       Default network + filesystem policy
```

The blueprint runtime (TypeScript) lives in the plugin source tree:

```text
nemoclaw/src/blueprint/
├── runner.ts                       CLI runner: plan / apply / status / rollback
├── ssrf.ts                         SSRF endpoint validation (IP + DNS checks)
├── snapshot.ts                     Migration snapshot / restore lifecycle
├── state.ts                        Persistent run state management
```

### Blueprint Lifecycle

```{mermaid}
flowchart LR
    A[resolve] --> B[verify digest]
    B --> C[plan]
    C --> D[apply]
    D --> E[status]
```

1. Resolve. The plugin locates the blueprint artifact and checks the version against `min_openshell_version` and `min_openclaw_version` constraints in `blueprint.yaml`.
2. Verify. The plugin checks the artifact digest against the expected value.
3. Plan. The runner determines what OpenShell resources to create or update, such as the gateway, providers, sandbox, inference route, and policy.
4. Apply. The runner executes the plan by calling `openshell` CLI commands.
5. Status. The runner reports current state.

## Agent Sandbox Pattern

Each supported agent is a tenant inside an OpenShell sandbox.
The tenant adapter supplies the runtime-specific contract while OpenShell supplies the isolation boundary.

```{mermaid}
flowchart LR
    OS["OpenShell sandbox runtime"]

    subgraph OC["agents/openclaw"]
      OCM["manifest.yaml"]
      OCP["openclaw-sandbox.yaml"]
      OCS["scripts/nemoclaw-start.sh"]
    end

    subgraph ZC["agents/zeroclaw"]
      ZCM["manifest.yaml"]
      ZCP["policy-additions.yaml"]
      ZCS["start.sh"]
    end

    subgraph HM["agents/hermes"]
      HMM["manifest.yaml"]
      HMP["policy-additions.yaml"]
      HMS["start.sh"]
    end

    OCM --> OS
    OCP --> OS
    OCS --> OS
    ZCM --> OS
    ZCP --> OS
    ZCS --> OS
    HMM --> OS
    HMP --> OS
    HMS --> OS
```

The pattern is the same for all three runtimes:

| Adapter element | Purpose |
|-----------------|---------|
| Manifest | Declares language, install method, binary path, gateway command, health probe, config layout, API surface, and phone-home hosts. |
| Policy | Adds runtime-specific filesystem layout, process user, package registry, messaging endpoints, and phone-home allowlist. |
| Entrypoint | Verifies immutable config, prepares writable state, applies proxy settings, drops capabilities where possible, and starts the gateway process. |
| Image | Installs the runtime and supporting packages, generates build-time config, and pins config hashes for startup verification. |

OpenClaw still uses legacy root-level image and entrypoint paths recorded in `agents/openclaw/manifest.yaml`.
ZeroClaw and Hermes keep their image, policy, config generator, and entrypoint files directly under `agents/<name>/`.

## Sandbox Environment

The sandbox runs the agent image selected by the adapter.
Inside the sandbox:

- The selected agent runs with its NemoClaw adapter or plugin installed.
- Inference calls are routed through OpenShell to the configured provider.
- Network egress is restricted by the selected agent policy.
- Filesystem access uses an immutable config directory plus a writable state directory.

| Agent | Immutable config | Writable state | Gateway port |
|-------|------------------|----------------|--------------|
| OpenClaw | `/sandbox/.openclaw` | `/sandbox/.openclaw-data` | `18789` |
| ZeroClaw | `/sandbox/.zeroclaw` | `/sandbox/.zeroclaw-data` | `42617` |
| Hermes | `/sandbox/.hermes` | `/sandbox/.hermes-data` | `8642` public, `18642` internal |

## Inference Routing

Inference requests from the agent never leave the sandbox directly.
OpenShell intercepts them and routes to the configured provider:

```text
Agent (sandbox)  ──▶  OpenShell gateway  ──▶  NVIDIA Endpoint (build.nvidia.com)
```

Refer to [Inference Options](../inference/inference-options.md) for provider configuration details.

## Host-Side State and Config

NemoClaw keeps its operator-facing state on the host rather than inside the sandbox.

| Path | Purpose |
|---|---|
| `~/.nemoclaw/credentials.json` | Provider credentials saved during onboarding. Stored as plaintext JSON protected by local filesystem permissions; see [Credential Storage](../security/credential-storage.md). |
| `~/.nemoclaw/sandboxes.json` | Registered sandbox metadata, including the default sandbox selection. |
| `~/.openclaw/openclaw.json` | Host OpenClaw configuration that NemoClaw snapshots or restores during migration flows. |

The following environment variables configure optional services and local access.

| Variable | Purpose |
|---|---|
| `TELEGRAM_BOT_TOKEN` | Telegram bot token you provide before `nemoclaw onboard`. OpenShell stores it in a provider; the sandbox receives placeholders, not the raw secret. |
| `TELEGRAM_ALLOWED_IDS` | Comma-separated Telegram user or chat IDs for allowlists when onboarding applies channel restrictions. |
| `CHAT_UI_URL` | URL for the optional chat UI endpoint. |
| `NEMOCLAW_DISABLE_DEVICE_AUTH` | Build-time-only toggle that disables gateway device pairing when set to `1` before the sandbox image is created. |

For normal setup and reconfiguration, prefer `nemoclaw onboard` over editing these files by hand.
Do not treat `NEMOCLAW_DISABLE_DEVICE_AUTH` as a runtime setting for an already-created sandbox.

## Related Agent Runbooks

- [OpenClaw](../agents/openclaw.md) documents the legacy/default adapter path.
- [ZeroClaw](../agents/zeroclaw.md) documents the primary `nclawzero/distro` runtime.
- [Hermes](../agents/hermes.md) documents the Nous Research Hermes Agent adapter.
