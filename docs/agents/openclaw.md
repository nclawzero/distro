---
title:
  page: "Running OpenClaw Inside the NemoClaw Sandbox"
  nav: "OpenClaw"
description:
  main: "Run OpenClaw inside a NemoClaw-managed OpenShell sandbox, including the manifest contract, policy semantics, entrypoint behavior, health probe, and troubleshooting."
  agent: "Explains the OpenClaw adapter under NemoClaw, including install path, manifest fields, policy-additions semantics, start script behavior, sandbox boundaries, health probe, and troubleshooting. Use when running or debugging OpenClaw in NemoClaw."
keywords: ["openclaw nemoclaw sandbox", "openclaw openshell", "openclaw manifest policy start"]
topics: ["generative_ai", "ai_agents"]
tags: ["openclaw", "openshell", "sandboxing", "security"]
content:
  type: how_to
  difficulty: intermediate
  audience: ["developer", "engineer"]
status: published
---

<!--
  SPDX-FileCopyrightText: Copyright (c) 2026 Jason Perlow. All rights reserved.
  SPDX-License-Identifier: Apache-2.0
-->

# OpenClaw

OpenClaw is the original NemoClaw agent tenant: a Node/TypeScript gateway-based assistant runtime with a dashboard, device-pairing flow, messaging integrations, and a plugin ecosystem.
In this repository the OpenClaw adapter is represented by `agents/openclaw/manifest.yaml`, while several image, policy, and entrypoint artifacts still live at their legacy root-level paths for backward compatibility.

Use OpenClaw when you want the upstream NemoClaw behavior: browser dashboard on port `18789`, OpenClaw application-layer security controls, device pairing, and the OpenClaw plugin model.

## Install Path

The OpenClaw base image installs the OpenClaw CLI with npm.
The version is controlled by `OPENCLAW_VERSION` in `Dockerfile.base`; the current manifest expects `2026.4.2`.
The runtime image then builds and installs the NemoClaw TypeScript plugin before generating `/sandbox/.openclaw/openclaw.json`.

For direct image work, the relevant files are:

| File | Purpose |
|------|---------|
| `agents/openclaw/manifest.yaml` | Declares OpenClaw as the `openclaw` agent adapter and points to the legacy artifact paths. |
| `Dockerfile.base` | Installs Node, system packages, `gosu`, users, `.openclaw` directory layout, and the `openclaw` CLI. |
| `Dockerfile` | Builds the NemoClaw plugin, generates `openclaw.json`, pins the config hash, and installs the entrypoint. |
| `scripts/nemoclaw-start.sh` | Starts the gateway, verifies config integrity, applies runtime host-owned overrides, and drops privileges. |
| `nemoclaw-blueprint/policies/openclaw-sandbox.yaml` | Default filesystem, process, and network policy for the OpenClaw sandbox. |

## Manifest Contract

`agents/openclaw/manifest.yaml` declares the runtime contract consumed by the multi-agent plan:

| Field | OpenClaw value |
|-------|----------------|
| `language` | `nodejs` |
| `install_method` | `npm` |
| `binary_path` | `/usr/local/bin/openclaw` |
| `gateway_command` | `openclaw gateway run` |
| `health_probe.url` | `http://localhost:18789/` |
| `config.immutable_dir` | `/sandbox/.openclaw` |
| `config.writable_dir` | `/sandbox/.openclaw-data` |
| `config.format` | `json` |
| `device_pairing` | `true` |
| `phone_home_hosts` | `openclaw.ai`, `docs.openclaw.ai`, `clawhub.ai` |

The manifest also records that OpenClaw currently uses legacy artifact paths: `Dockerfile`, `Dockerfile.base`, `scripts/nemoclaw-start.sh`, and `nemoclaw-blueprint/policies/openclaw-sandbox.yaml`.

## Policy Semantics

The default OpenClaw policy is deny-by-default.
It makes `/sandbox` and `/sandbox/.openclaw` read-only, then grants write access only to specific state paths such as `/sandbox/.openclaw-data`, `/sandbox/.nemoclaw`, `/tmp`, and `/dev/null`.

OpenClaw-specific egress is limited to:

| Policy block | Purpose |
|--------------|---------|
| `clawhub` | ClawHub access for OpenClaw plugin discovery and related flows. |
| `openclaw_api` | OpenClaw API access. |
| `openclaw_docs` | Read-only OpenClaw documentation access. |
| `npm_registry` | Read-only npm registry access scoped to the OpenClaw binary for plugin install flows. |
| `telegram`, `discord`, `slack` | Messaging endpoints, restricted to Node processes in the baseline policy. |

Endpoint rules are binary-scoped where possible.
If an agent needs broader package or source-code access, apply an explicit preset instead of widening the baseline policy.

## Entrypoint Behavior

`scripts/nemoclaw-start.sh` is the OpenClaw entrypoint.
It performs the following sequence before launching the gateway:

1. Sets `ulimit -u 512` to reduce fork-bomb risk.
2. Locks down `PATH` and redirects common tool caches to `/tmp` because `/sandbox` is read-only.
3. Drops Linux capabilities with `capsh` when `CAP_SETPCAP` is available.
4. Verifies `/sandbox/.openclaw/.config-hash` against `openclaw.json`.
5. Applies host-owned runtime model and CORS overrides before immutable hardening.
6. Exports the gateway token into shell startup files for interactive sessions.
7. Installs a shell guard that blocks `openclaw configure` inside the sandbox.
8. Validates every symlink under `/sandbox/.openclaw` and hardens the directory with `chattr +i` when available.
9. Starts `openclaw gateway run` as the `gateway` user through `gosu`, then starts the auto-pair watcher as the `sandbox` user.

If OpenShell starts the container as a non-root user, the script falls back to running as that user and prints that privilege separation is disabled.

## Sandbox Boundaries

OpenClaw has a split filesystem layout:

| Path | Mode | Purpose |
|------|------|---------|
| `/sandbox/.openclaw` | Read-only, root-owned, integrity-verified | Gateway configuration, auth token, CORS settings, and symlinks to state directories. |
| `/sandbox/.openclaw-data` | Writable | Agent state, plugins, workspace, skills, hooks, identity, devices, memory, credentials, and messaging state. |
| `/sandbox/.nemoclaw` | Writable with root-owned blueprint contents protected by sticky-bit behavior | NemoClaw plugin state, migration state, snapshots, and cached blueprint data. |
| `/tmp` | Writable | Runtime logs and redirected tool caches. |

The gateway runs as `gateway`.
Interactive agent commands run as `sandbox`.
That separation prevents the agent user from killing the gateway and restarting it against a tampered config.

## Health Probe

OpenClaw publishes the dashboard and gateway on port `18789`.
Check the sandbox from the host:

```bash
curl http://localhost:18789/
```

The entrypoint prints the local and remote dashboard URLs, including the gateway token when one is present.

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Gateway does not start | Inspect `/tmp/gateway.log` inside the sandbox. A missing or failing `.config-hash` check means the immutable config does not match the build-time hash. |
| Browser dashboard cannot pair | Check `/tmp/auto-pair.log`. The auto-pair watcher approves only expected browser or CLI client modes and times out after its deadline. |
| `openclaw configure` fails | This is expected. The entrypoint installs a configure guard because `/sandbox/.openclaw` is immutable. Re-run host-side onboarding or rebuild the sandbox instead. |
| Network request is blocked | Review `nemoclaw-blueprint/policies/openclaw-sandbox.yaml` and the OpenShell network-policy UI. Add a narrow endpoint or preset rather than opening all egress. |
| Package install fails | The baseline npm rule is GET-only and scoped to the OpenClaw binary. Broader npm usage requires an explicit policy preset. |

For exact command invocation and runtime guards, read `scripts/nemoclaw-start.sh`.
