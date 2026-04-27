---
title:
  page: "Running ZeroClaw Inside the NemoClaw Sandbox"
  nav: "ZeroClaw"
description:
  main: "Run ZeroClaw inside a NemoClaw-managed OpenShell sandbox, including Rust binary packaging, TOML config, OpenAI-compatible API, policy semantics, and troubleshooting."
  agent: "Explains the ZeroClaw adapter under NemoClaw, including install path, manifest fields, policy-additions semantics, start script behavior, sandbox boundaries, health probe, OpenAI-compatible API surface, and troubleshooting. Use when running or debugging ZeroClaw in NemoClaw."
keywords: ["zeroclaw nemoclaw sandbox", "zeroclaw openshell", "zeroclaw openai compatible"]
topics: ["generative_ai", "ai_agents"]
tags: ["zeroclaw", "openshell", "sandboxing", "openai_compatible"]
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

# ZeroClaw

ZeroClaw is the primary agent runtime for `nclawzero/distro`.
It is a Rust-based agent runtime packaged as a prebuilt binary, configured with TOML, and exposed through an OpenAI-compatible API on port `42617`.
Unlike OpenClaw, it does not use the browser device-pairing flow in NemoClaw-managed deployments.

Use ZeroClaw when you want the `nclawzero` path described in the README: a lighter Rust runtime, OpenAI-compatible `/v1/*` endpoints, and routing across the supported provider matrix.

## Install Path

The ZeroClaw base image downloads a prebuilt ZeroClaw release binary from GitHub Releases and verifies it against the upstream `SHA256SUMS` file.
The current Dockerfile default is `ZEROCLAW_VERSION=v0.6.9`.
The runtime image then compiles the NemoClaw WASM plugin, generates `config.toml`, installs the plugin into `/sandbox/.zeroclaw-data/plugins/nemoclaw`, and pins a SHA256 config hash.

For direct image work, the relevant files are:

| File | Purpose |
|------|---------|
| `agents/zeroclaw/manifest.yaml` | Declares the ZeroClaw runtime contract. |
| `agents/zeroclaw/Dockerfile.base` | Downloads ZeroClaw, installs runtime packages and `gosu`, creates users, and builds the `.zeroclaw` directory layout. |
| `agents/zeroclaw/Dockerfile` | Compiles the WASM plugin, generates config, installs the entrypoint, and pins config integrity. |
| `agents/zeroclaw/generate-config.ts` | Writes `/sandbox/.zeroclaw/config.toml` from NemoClaw build arguments. |
| `agents/zeroclaw/policy-additions.yaml` | Adds ZeroClaw-specific filesystem and network policy. |
| `agents/zeroclaw/start.sh` | Starts `zeroclaw gateway start` with config verification and privilege separation. |

## Manifest Contract

`agents/zeroclaw/manifest.yaml` declares the runtime contract:

| Field | ZeroClaw value |
|-------|----------------|
| `language` | `rust` |
| `install_method` | `prebuilt` |
| `binary_path` | `/usr/local/bin/zeroclaw` |
| `gateway_command` | `zeroclaw gateway start` |
| `health_probe.url` | `http://localhost:42617/health` |
| `config.immutable_dir` | `/sandbox/.zeroclaw` |
| `config.writable_dir` | `/sandbox/.zeroclaw-data` |
| `config.format` | `toml` |
| `device_pairing` | `false` |
| `web_auth_method` | `bearer_token` |
| `web_auth_env` | `ZEROCLAW_API_KEY` |
| `phone_home_hosts` | `zeroclaw-labs.com`, `api.zeroclaw-labs.com` |

The manifest states that ZeroClaw supports Telegram, Discord, and Slack through its channel plugin system.
The sandbox adapter disables OpenClaw-style pairing and sets `require_pairing = false` in the generated TOML config.

## Configuration

`agents/zeroclaw/generate-config.ts` writes TOML into `/sandbox/.zeroclaw/config.toml`.
The generated config includes:

| Section | Behavior |
|---------|----------|
| Core provider | Maps NemoClaw provider settings to ZeroClaw's native provider name when the base URL is known. Falls back to `custom:<url>` for custom endpoints. |
| Gateway | Binds to `[::]` on port `42617` with `allow_public_bind = true` and `require_pairing = false`. |
| Plugins | Enables the plugin system and points `plugins_dir` at `.zeroclaw-data/plugins`. |
| Messaging | Bakes placeholder tokens such as `openshell:resolve:env:TELEGRAM_BOT_TOKEN` when channels are configured during onboarding. |

ZeroClaw binds directly to all interfaces, so there is no `socat` forwarder.
The OpenShell port forward can target port `42617` directly.

## API Surface

ZeroClaw exposes an OpenAI-compatible API on:

```text
http://localhost:42617/v1
```

Use this endpoint from OpenAI-compatible frontends and SDKs.
The health endpoint is:

```bash
curl http://localhost:42617/health
```

The README describes the current routing model as 27 routes across eight providers plus local Ollama, validated by the 25-check provider harness.
Keep provider changes synchronized with the README, `agents/zeroclaw/generate-config.ts`, and the relevant tests.

## Policy Semantics

`agents/zeroclaw/policy-additions.yaml` mirrors the Hermes split-config pattern with ZeroClaw-specific paths:

| Path | Mode | Purpose |
|------|------|---------|
| `/sandbox/.zeroclaw` | Read-only | Immutable TOML config and symlinks to writable state. |
| `/sandbox/.zeroclaw-data` | Writable | Workspace, memory, channel config, cron, logs, plugins, and cache. |
| `/sandbox` | Writable in the ZeroClaw policy | Workdir access for the runtime. |
| `/tmp` | Writable | Logs and temporary files. |

The policy adds ZeroClaw-specific phone-home access for `zeroclaw-labs.com` and `api.zeroclaw-labs.com`.
It also includes messaging endpoints restricted to `/usr/local/bin/zeroclaw`.
ZeroClaw is a Rust binary, so the policy does not add PyPI runtime access.

## Entrypoint Behavior

`agents/zeroclaw/start.sh` launches ZeroClaw safely:

1. Sets a process count limit of `512`.
2. Drops Linux capabilities with `capsh` when available.
3. Detects the OpenShell proxy and sets proxy environment variables only when the proxy is reachable.
4. Verifies `/sandbox/.zeroclaw/.config-hash`.
5. Copies the verified immutable `config.toml` into `/sandbox/.zeroclaw-data/config.toml`.
6. Installs a configure guard that blocks `zeroclaw onboard` and `zeroclaw service` inside the sandbox.
7. Validates `.zeroclaw` symlinks and hardens the directory with `chattr +i` when available.
8. Starts `zeroclaw gateway start --config-dir /sandbox/.zeroclaw-data` as the `gateway` user.

If the container starts non-root, the script still verifies config integrity and starts the gateway, but prints that privilege separation is disabled.

## Troubleshooting

| Symptom | Check |
|---------|-------|
| `curl /health` fails | Inspect `/tmp/gateway.log` inside the sandbox and confirm port `42617` is forwarded. |
| Config changes do not take effect | `config.toml` is immutable at build time. Re-run host-side onboarding or rebuild the image. The entrypoint copies verified config into `.zeroclaw-data` only after the hash check passes. |
| `zeroclaw onboard` fails inside the sandbox | This is expected. The shell guard blocks config-mutating commands inside the sandbox. |
| Network requests fail in standalone Docker | The start script detects whether the OpenShell proxy is reachable. Outside OpenShell, direct internet access is used if no proxy is found. |
| Messaging token substitution fails | Confirm the channel was baked into `config.toml` and the corresponding OpenShell provider is configured. Placeholder tokens flow through the proxy at egress. |

For exact invocation and guard behavior, read `agents/zeroclaw/start.sh`.
