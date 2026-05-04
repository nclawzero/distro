---
name: "nclawzero-zeroclaw-get-started"
description: "Getting started with ZeroClaw on nclawzero. Covers installing zeroclaw v0.6.9 on Pi/ARM64, creating config.toml, setting API keys, starting the gateway daemon, verifying health, accessing the web dashboard, and running the first inference via webhook. Use when onboarding ZeroClaw for the first time on edge or embedded devices."
---

<!-- SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved. -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- SPDX-FileCopyrightText: Copyright (c) 2026 Jason Perlow. All rights reserved. -->

# Getting Started with ZeroClaw on nclawzero

Install ZeroClaw v0.6.9, configure it for edge deployment, start the gateway, and run your first inference request.

> **Alpha software:** nclawzero is a research project exploring ZeroClaw agents inside OpenShell sandboxes on memory-constrained and resource-constrained devices.
> Interfaces may change without notice.

## Prerequisites

- Raspberry Pi 4/5 or any ARM64 Linux device (also works on x86_64)
- Docker installed and running
- An inference provider API key (NVIDIA, Together AI, Groq, OpenAI, or a local Ollama instance)
- Network access to the inference provider endpoint

## Step 1: Install ZeroClaw v0.6.9

Download the ZeroClaw binary for your architecture from GitHub Releases and place it on your PATH.

```bash
# ARM64 (Raspberry Pi, Jetson, etc.)
curl -fsSL https://github.com/zeroclaw-labs/zeroclaw/releases/download/v0.6.9/zeroclaw-linux-arm64 \
  -o /usr/local/bin/zeroclaw
chmod +x /usr/local/bin/zeroclaw

# x86_64 (standard Linux)
curl -fsSL https://github.com/zeroclaw-labs/zeroclaw/releases/download/v0.6.9/zeroclaw-linux-x86_64 \
  -o /usr/local/bin/zeroclaw
chmod +x /usr/local/bin/zeroclaw
```

Verify the installation:

```bash
zeroclaw --version
# zeroclaw 0.6.9
```

## Step 2: Create the Configuration Directory

```bash
mkdir -p ~/.zeroclaw
```

## Step 3: Create `~/.zeroclaw/config.toml`

Write a minimal TOML config with your provider and model. The example below uses Together AI. See the `nclawzero-zeroclaw-config` skill for the full configuration reference and other providers.

```toml
default_provider = "together"
default_model = "meta-llama/Llama-3.1-8B-Instruct"
default_temperature = 0.7

[gateway]
port = 42617
host = "[::]"
allow_public_bind = true
require_pairing = false
```

Set file permissions so only the owner can read the config:

```bash
chmod 600 ~/.zeroclaw/config.toml
```

## Step 4: Set API Keys in `~/.zeroclaw/.env`

Create a `.env` file with your provider API key. The variable name depends on the provider you chose.

```bash
cat > ~/.zeroclaw/.env << 'EOF'
# Together AI
TOGETHER_API_KEY=your-together-api-key-here

# Uncomment and set the key for your provider:
# GROQ_API_KEY=your-groq-key
# NVIDIA_API_KEY=nvapi-your-nvidia-key
# OPENAI_API_KEY=sk-your-openai-key
# XAI_API_KEY=your-xai-key
# PERPLEXITY_API_KEY=your-perplexity-key
EOF

chmod 600 ~/.zeroclaw/.env
```

## Step 5: Start the Gateway

Launch the ZeroClaw daemon. The gateway binds to port 42617 on all interfaces.

```bash
zeroclaw daemon
```

On first start you should see output similar to:

```text
[gateway] ZeroClaw API:  http://127.0.0.1:42617/v1
[gateway] Health:        http://127.0.0.1:42617/health
[gateway] Connect any OpenAI-compatible frontend to this endpoint.
```

To run the daemon in the background:

```bash
nohup zeroclaw daemon > /tmp/zeroclaw.log 2>&1 &
```

## Step 6: Verify Health

Send a health probe to confirm the gateway is running:

```bash
curl http://localhost:42617/health
```

Expected response:

```json
{"status":"ok"}
```

If the response includes `"stub":true`, you are running the stub binary (for offline testing). The real binary does not include the stub marker.

## Step 7: Access the Web Dashboard

Open a browser and navigate to:

```
http://<device-ip>:42617/
```

On the device itself:

```
http://localhost:42617/
```

The dashboard shows the current model, provider status, and recent inference requests.

## Step 8: First Inference via Webhook

Send a test inference request through the webhook endpoint:

```bash
curl -X POST http://localhost:42617/webhook \
  -H 'Content-Type: application/json' \
  -d '{
    "message": "Hello, what can you do?"
  }'
```

Alternatively, use the OpenAI-compatible chat completions endpoint:

```bash
curl -X POST http://localhost:42617/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "meta-llama/Llama-3.1-8B-Instruct",
    "messages": [
      {"role": "user", "content": "Hello, what can you do?"}
    ]
  }'
```

A successful response confirms the full pipeline is working: gateway, provider routing, and inference.

## Running Inside an OpenShell Sandbox

For sandboxed deployment (the primary nclawzero use case), use NemoClaw to onboard with the ZeroClaw agent:

```bash
nemoclaw onboard --agent zeroclaw
```

This builds the sandbox image, generates `config.toml` from your provider settings, and starts the container with full security hardening (Landlock, seccomp, network policies, privilege separation).

## Test Targets

nclawzero maintains two Raspberry Pi test targets for ZeroClaw edge validation:

| Target | IP | Role |
|--------|-----|------|
| zeropi | 10.0.0.56 | Minimal footprint test target |
| clawpi | 10.0.0.54 | Full-featured test target |

Deploy and test on a target:

```bash
scripts/deploy-test-target.sh --ssh pi@10.0.0.56 --nvidia-key nvapi-xxx
```

## Related Skills

- `nclawzero-zeroclaw-config` — Full configuration reference (providers, model routes, gateway settings)
- `nclawzero-zeroclaw-security` — Security hardening reference for ZeroClaw containers
- `nclawzero-testing` — Testing guide (unit tests, E2E, test harness, deploy scripts)
- `nclawzero-skills-guide` — Skills catalog for nclawzero
