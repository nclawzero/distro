---
title:
  page: "Running Hermes Agent Inside the NemoClaw Sandbox"
  nav: "Hermes"
description:
  main: "Run Hermes Agent from Nous Research inside a NemoClaw-managed OpenShell sandbox, including filesystem layout, network policy, package management, gateway forwarding, OpenAI-compatible API, and troubleshooting."
  agent: "Explains how Hermes Agent runs inside NemoClaw, including the immutable and writable filesystem layout, Nous Research network policy, PyPI package flow, sandbox user model, dropped capabilities, YAML config, gateway forwarding from 18642 to 8642, health probe, OpenAI-compatible API, and troubleshooting. Use when answering how to run Hermes inside the NemoClaw sandbox."
keywords: ["hermes agent nemoclaw sandbox", "nous research hermes openshell", "hermes openai compatible"]
topics: ["generative_ai", "ai_agents"]
tags: ["hermes", "nous_research", "openshell", "sandboxing", "openai_compatible"]
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

# Hermes

Hermes Agent is a Python-based self-improving AI agent from Nous Research.
The NemoClaw adapter runs Hermes as an OpenShell sandbox tenant with the same security pattern used for the claw-family runtimes: immutable config, writable state, deny-by-default egress, process privilege separation, and host-owned inference routing.

Run Hermes inside NemoClaw when you want to evaluate the Hermes learning loop and OpenAI-compatible API while keeping filesystem writes, network egress, package installation, and credentials inside the OpenShell policy boundary.
Run standalone Hermes only when you are comfortable managing those boundaries yourself.

## Adapter Files

| File | Purpose |
|------|---------|
| `agents/hermes/manifest.yaml` | Declares the Hermes runtime contract, ports, config format, auth method, phone-home hosts, and package registry. |
| `agents/hermes/Dockerfile.base` | Installs Python, pip, `socat`, `gosu`, users, the `.hermes` directory layout, and Hermes Agent. |
| `agents/hermes/Dockerfile` | Applies sandbox patches, generates Hermes config, installs the NemoClaw plugin, writes `SOUL.md`, and pins config integrity. |
| `agents/hermes/generate-config.ts` | Writes `/sandbox/.hermes/config.yaml` and `/sandbox/.hermes/.env` from NemoClaw build arguments. |
| `agents/hermes/policy-additions.yaml` | Adds Hermes-specific filesystem, process, and network policy. |
| `agents/hermes/start.sh` | Starts the decode proxy, Hermes gateway, and `socat` forwarder with config verification and privilege separation. |
| `agents/hermes/decode-proxy.py` | URL-decodes OpenShell placeholder paths before forwarding Python HTTP client traffic to the OpenShell proxy. |

## Install Path

The manifest records the upstream install method as `curl install.sh | bash` with the binary at `/usr/local/bin/hermes`.
The repository Dockerfile uses a reproducible image path instead: `agents/hermes/Dockerfile.base` installs the pinned Hermes release from the GitHub release tarball with pip and verifies the installed CLI with `hermes --version`.

The current default is:

| Setting | Value |
|---------|-------|
| Hermes release | `HERMES_VERSION=v2026.4.8` |
| Manifest expected version | `2026.4.8` |
| Version constraint | `>=0.8.0` |
| Binary path | `/usr/local/bin/hermes` |
| Gateway command | `hermes gateway run` |

:::{note}
If the project standardizes on the curl installer in the future, update `agents/hermes/Dockerfile.base` and this page together.
The current public tree uses the direct pip-from-release path for the container image.
:::

## Configuration

Hermes uses YAML plus `.env`, not JSON or TOML.
`agents/hermes/generate-config.ts` writes both files at image build time:

| File | Path | Purpose |
|------|------|---------|
| `config.yaml` | `/sandbox/.hermes/config.yaml` | Hermes model, custom OpenAI-compatible base URL, terminal settings, agent defaults, memory, skills, display, messaging platforms, and API server settings. |
| `.env` | `/sandbox/.hermes/.env` | API server host and port plus OpenShell placeholder tokens for configured messaging channels. |
| `.config-hash` | `/sandbox/.hermes/.config-hash` | SHA256 checksums for `config.yaml` and `.env`, verified at every startup. |

The generated model block uses `provider: custom` with `base_url` set from `NEMOCLAW_INFERENCE_BASE_URL`, which defaults to `https://inference.local/v1`.
That sends model traffic through OpenShell's inference proxy rather than embedding provider credentials in the container.

## Sandbox Semantics

Hermes uses a split home layout:

| Path | Mode | Purpose |
|------|------|---------|
| `/sandbox/.hermes` | Immutable config directory | Root-owned source config, `.env`, config hash, and symlinks to writable state. Landlock marks this path read-only. |
| `/sandbox/.hermes-data` | Writable agent state | Memories, sessions, skills, plugins, cron, logs, skins, plans, workspace, profiles, cache, and pairing state. |
| `/tmp` | Writable runtime area | Gateway logs and temporary process state. |

Hermes itself writes PID files, state databases, and channel metadata into `HERMES_HOME`.
Because `/sandbox/.hermes` is immutable, `agents/hermes/start.sh` verifies the immutable config hash, then copies `config.yaml` and `.env` into `/sandbox/.hermes-data` and runs Hermes with `HERMES_HOME=/sandbox/.hermes-data`.

The image also writes a default `SOUL.md` into `/sandbox/.hermes-data/memories/SOUL.md` and symlinks it from `/sandbox/.hermes/SOUL.md`, because Hermes expects that file in its home directory.

## Network Policy

Hermes phones home to Nous Research endpoints, not OpenClaw or ClawHub endpoints.
`agents/hermes/policy-additions.yaml` adds:

| Policy block | Hosts | Binary scope |
|--------------|-------|--------------|
| `nous_research` | `nousresearch.com`, `hermes-agent.nousresearch.com`, `api.nousresearch.com` | `/usr/local/bin/hermes`, `/usr/bin/python3.11` |
| `pypi` | `pypi.org`, `files.pythonhosted.org` | `/usr/local/bin/pip3`, `/usr/bin/python3.11` |
| `telegram` | `api.telegram.org` | `/usr/local/bin/node`, `/usr/bin/python3.11` |
| `discord` | `discord.com`, `gateway.discord.gg`, `cdn.discordapp.com` | `/usr/local/bin/node`, `/usr/bin/python3.11` |

Hermes uses PyPI for Python dependencies and plugin or skill dependency installs.
This is different from OpenClaw's npm registry rule and ZeroClaw's Rust/WASM plugin flow.

The Dockerfile also patches Hermes's Telegram fallback transport so it does not rewrite `api.telegram.org` to raw IP addresses.
Raw IP fallback bypasses hostname-based policy and is rejected by OpenShell's L7 proxy.

## Process Boundary

The Hermes container creates separate `gateway` and `sandbox` users.
The entrypoint starts as root so it can verify and harden configuration, then launches `hermes gateway run` as the `gateway` user with `gosu`.
Interactive commands run as `sandbox`.

At startup, `agents/hermes/start.sh` tries to drop these Linux capabilities from the bounding set:

```text
cap_net_raw
cap_dac_override
cap_sys_chroot
cap_fsetid
cap_setfcap
cap_mknod
cap_audit_write
cap_net_bind_service
```

The entrypoint also sets both soft and hard process limits to `512` where the container runtime permits it.
This limits fork-bomb blast radius inside the sandbox.

## Gateway Run

Hermes is configured with an internal API server on `127.0.0.1:18642`.
The adapter exposes the public sandbox port with `socat`:

```text
0.0.0.0:8642 -> 127.0.0.1:18642
```

The health endpoint is:

```bash
curl http://localhost:8642/health
```

Expected response:

```json
{"status":"ok","platform":"hermes-agent"}
```

The OpenAI-compatible API base URL is:

```text
http://localhost:8642/v1
```

Connect OpenAI-compatible frontends such as Open WebUI or LobeChat to that `/v1` endpoint.
Hermes does not use OpenClaw's browser device-pairing flow.
The manifest records bearer-token web auth through `API_SERVER_KEY`.

## Proxy Compatibility

Python HTTP clients can URL-encode the colon characters in OpenShell placeholders such as `openshell:resolve:env:TELEGRAM_BOT_TOKEN`.
OpenShell's L7 proxy expects the undecoded placeholder pattern.

To handle that, `agents/hermes/start.sh` launches `agents/hermes/decode-proxy.py` on `127.0.0.1:3129`.
Hermes receives `HTTP_PROXY` and `HTTPS_PROXY` pointing at this local decode proxy, which forwards decoded requests to the OpenShell proxy at `10.200.0.1:3128`.

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Gateway will not start | Inspect `/tmp/gateway.log` inside the sandbox. A missing `.config-hash` or failed SHA256 check means `config.yaml` or `.env` was changed after image build. |
| Health probe fails | Confirm `hermes gateway run` started, `socat` is installed, and the forwarder logged `0.0.0.0:8642 -> 127.0.0.1:18642`. The internal server binds `127.0.0.1:18642`; the host-facing endpoint is `8642`. |
| Network allowlist issues | Check `agents/hermes/policy-additions.yaml`. Hermes needs Nous Research endpoints for Hermes-specific flows and PyPI endpoints for Python package dependencies. OpenClaw/ClawHub rules do not cover Hermes. |
| Messaging placeholders are not rewritten | Confirm the decode proxy is listening on `127.0.0.1:3129`. Without it, Python clients can encode placeholder colons before the request reaches OpenShell. |
| Fork-bomb protection warning | Some runtimes restrict `ulimit` changes. The entrypoint warns but continues if it cannot set `nproc` to `512`. Apply the equivalent limit in the outer runtime if required. |
| Config-tampering detection blocks startup | Rebuild or re-run host-side onboarding. Do not edit `/sandbox/.hermes/config.yaml` or `/sandbox/.hermes/.env` inside the sandbox; the entrypoint verifies SHA256 hashes before copying config into `.hermes-data`. |
| `hermes setup` or `hermes doctor` fails inside the sandbox | This is expected. The shell guard blocks config-mutating commands because the source config is read-only and integrity-verified. |

For exact process invocation, proxy setup, and hardening behavior, read `agents/hermes/start.sh`.
