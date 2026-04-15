---
name: "nclawzero-zeroclaw-config"
description: "ZeroClaw configuration reference for nclawzero. Covers the TOML config structure, provider setup for Together AI, Groq, NVIDIA inference proxy, OpenAI, xAI, Perplexity, Gemini, and Ollama, model route hints, gateway config, and NVIDIA inference proxy configuration. Use when configuring ZeroClaw providers, changing models, adjusting gateway settings, or setting up the NVIDIA inference proxy."
---

<!-- SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved. -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- SPDX-FileCopyrightText: Copyright (c) 2026 Jason Perlow. All rights reserved. -->

# ZeroClaw Configuration Reference

Complete reference for `~/.zeroclaw/config.toml` and provider setup on nclawzero.

## Config File Location

ZeroClaw reads its configuration from `~/.zeroclaw/config.toml`. Inside a NemoClaw sandbox, the config lives at `/sandbox/.zeroclaw/config.toml` (immutable, Landlock-enforced) and is copied to `/sandbox/.zeroclaw-data/config.toml` (writable) at startup.

The config is generated at image build time by `agents/zeroclaw/generate-config.ts` from `NEMOCLAW_*` build args. Do not edit it inside the sandbox.

## TOML Config Structure

A complete config file has four sections: top-level defaults, model routes, gateway, and plugins.

```toml
# ── Top-level defaults ──────────────────────────────────────────
default_provider = "together"
default_model = "meta-llama/Llama-3.1-8B-Instruct"
default_temperature = 0.7

# ── Model routes (optional) ────────────────────────────────────
[[model_routes]]
pattern = "claude-*"
provider = "custom:https://integrate.api.nvidia.com/v1"

[[model_routes]]
pattern = "gpt-*"
provider = "openai"

[[model_routes]]
pattern = "llama-*"
provider = "together"

# ── Gateway ────────────────────────────────────────────────────
[gateway]
port = 42617
host = "[::]"
allow_public_bind = true
require_pairing = false

# ── Plugins ────────────────────────────────────────────────────
[plugins]
enabled = true
plugins_dir = "/sandbox/.zeroclaw-data/plugins"
```

## Top-Level Defaults

| Key | Type | Description |
|-----|------|-------------|
| `default_provider` | string | Provider name or `custom:<url>` for custom endpoints |
| `default_model` | string | Model identifier to use when no route matches |
| `default_temperature` | float | Sampling temperature (0.0 to 2.0) |

## Provider Setup

ZeroClaw resolves provider names to their API endpoints automatically. Set the corresponding API key in `~/.zeroclaw/.env` (or as an environment variable).

### Together AI

```toml
default_provider = "together"
default_model = "meta-llama/Llama-3.1-8B-Instruct"
```

```bash
# ~/.zeroclaw/.env
TOGETHER_API_KEY=your-key-here
```

Endpoint: `https://api.together.xyz/v1`

### Groq

```toml
default_provider = "groq"
default_model = "llama-3.1-70b-versatile"
```

```bash
# ~/.zeroclaw/.env
GROQ_API_KEY=your-key-here
```

Endpoint: `https://api.groq.com/openai/v1`

### NVIDIA Inference Proxy

The NVIDIA inference proxy routes through `integrate.api.nvidia.com`. This is the recommended provider for NemoClaw sandbox deployments.

```toml
default_provider = "nvidia"
default_model = "nvidia/llama-3.1-nemotron-70b-instruct"
```

```bash
# ~/.zeroclaw/.env
NVIDIA_API_KEY=nvapi-your-key-here
```

Endpoint: `https://integrate.api.nvidia.com/v1`

#### NVIDIA Proxy Model Names

The NVIDIA inference proxy supports proxied models from other providers using a prefixed naming convention:

| Model name | Upstream provider |
|------------|-------------------|
| `nvidia/llama-3.1-nemotron-70b-instruct` | NVIDIA native |
| `nvidia/nemotron-3-super-120b-a12b` | NVIDIA native |
| `azure/anthropic/claude-sonnet-4-6` | Anthropic via Azure |
| `azure/anthropic/claude-haiku-4-5` | Anthropic via Azure |
| `azure/anthropic/claude-opus-4-6` | Anthropic via Azure |

For proxied Anthropic models through NVIDIA, use the `azure/anthropic/` prefix with the NVIDIA API key.

### OpenAI

```toml
default_provider = "openai"
default_model = "gpt-5.4"
```

```bash
# ~/.zeroclaw/.env
OPENAI_API_KEY=sk-your-key-here
```

Endpoint: `https://api.openai.com/v1`

### xAI

```toml
default_provider = "xai"
default_model = "grok-3"
```

```bash
# ~/.zeroclaw/.env
XAI_API_KEY=your-key-here
```

Endpoint: `https://api.x.ai/v1`

### Perplexity

```toml
default_provider = "perplexity"
default_model = "llama-3.1-sonar-large-128k-online"
```

```bash
# ~/.zeroclaw/.env
PERPLEXITY_API_KEY=your-key-here
```

Endpoint: `https://api.perplexity.ai`

### Google Gemini

Gemini is accessed through a custom OpenAI-compatible endpoint:

```toml
default_provider = "custom:https://generativelanguage.googleapis.com/v1beta/openai"
default_model = "gemini-2.5-flash"
```

```bash
# ~/.zeroclaw/.env
GEMINI_API_KEY=your-key-here
```

### Ollama (Local)

```toml
default_provider = "ollama"
default_model = "qwen2.5:14b"
```

No API key required. Ollama must be running on `localhost:11434`.

Endpoint: `http://localhost:11434`

On Linux with Docker, make sure Ollama listens on all interfaces:

```bash
OLLAMA_HOST=0.0.0.0:11434 ollama serve
```

### Custom Endpoint

For any OpenAI-compatible server not in the known list:

```toml
default_provider = "custom:http://your-server:8000/v1"
default_model = "your-model-name"
```

```bash
# ~/.zeroclaw/.env
COMPATIBLE_API_KEY=your-key-or-dummy
```

## Model Routes

Model routes let ZeroClaw dispatch requests to different providers based on the requested model name. Routes are evaluated in order; the first match wins. If no route matches, the `default_provider` is used.

```toml
[[model_routes]]
pattern = "claude-*"
provider = "custom:https://integrate.api.nvidia.com/v1"

[[model_routes]]
pattern = "gpt-*"
provider = "openai"

[[model_routes]]
pattern = "llama-*"
provider = "together"
```

The `pattern` field supports glob-style wildcards (`*`).

## Gateway Configuration

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `port` | integer | `42617` | Port the gateway listens on |
| `host` | string | `"[::]"` | Bind address. `[::]` binds all interfaces (IPv4 and IPv6) |
| `allow_public_bind` | boolean | `true` | Allow binding to non-loopback addresses |
| `require_pairing` | boolean | `false` | Require device pairing before accepting requests. Disabled in NemoClaw sandboxes. |

The gateway port `42617` is fixed for NemoClaw sandbox deployments. OpenShell port-forwards to this port.

## NVIDIA Inference Proxy Configuration

When using the NVIDIA inference proxy inside a NemoClaw sandbox, the config is generated from build args:

| Build Arg | Maps To |
|-----------|---------|
| `NEMOCLAW_INFERENCE_BASE_URL` | `default_provider` (resolved via known provider map) |
| `NEMOCLAW_MODEL` | `default_model` |
| `NEMOCLAW_PROVIDER_KEY` | Provider hint for resolution |

The `generate-config.ts` script maps known base URLs to native provider names:

| Base URL | Provider Name |
|----------|---------------|
| `https://api.together.xyz/v1` | `together` |
| `https://api.groq.com/openai/v1` | `groq` |
| `https://api.openai.com/v1` | `openai` |
| `https://api.x.ai/v1` | `xai` |
| `https://integrate.api.nvidia.com/v1` | `nvidia` |
| `https://api.perplexity.ai` | `perplexity` |
| `http://localhost:11434` | `ollama` |

Unknown URLs fall back to `custom:<url>`.

## File Permissions

- `config.toml`: `600` (owner read/write only) in standalone mode; `444` (read-only) inside the sandbox image
- `.env`: `600` (owner read/write only)
- Inside a sandbox, config is chown to root and Landlock-enforced as read-only

## Related Skills

- `nclawzero-zeroclaw-get-started` — Installation and first run
- `nclawzero-zeroclaw-security` — Security hardening reference
- `nclawzero-testing` — Testing guide
- `nclawzero-skills-guide` — Skills catalog for nclawzero
