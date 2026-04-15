<!--
  SPDX-FileCopyrightText: Copyright (c) 2026 Jason Perlow. All rights reserved.
  SPDX-License-Identifier: Apache-2.0
-->

# nclawzero

[![License](https://img.shields.io/badge/License-Apache_2.0-blue)](LICENSE)
[![ZeroClaw](https://img.shields.io/badge/ZeroClaw-0.6.9-green)](https://github.com/zeroclaw-labs/zeroclaw/releases/tag/v0.6.9)
[![Harness](https://img.shields.io/badge/tests-25%2F25%20passed-brightgreen)](#test-results)

**nclawzero** is a research project exploring how to run [ZeroClaw](https://github.com/zeroclaw-labs/zeroclaw) agents inside hardened [OpenShell](https://github.com/NVIDIA/OpenShell) sandboxes on memory-constrained and resource-constrained devices for edge and embedded deployments. It started as a fork of [NVIDIA NemoClaw](https://github.com/NVIDIA/NemoClaw) but has diverged significantly — ZeroClaw replaces OpenClaw as the primary agent runtime, and the sandbox tooling, config generation, provider routing, and test harnesses are independently developed.

> **Experimental research software** — not production-ready. Use at your own risk. No support channel, SLA, or guarantee of compatibility with future upstream releases.

## What nclawzero does

- Runs ZeroClaw (a Rust-based AI agent) inside an OpenShell sandbox with Landlock, seccomp, and privilege separation via gosu
- Builds hardened container images with SHA-256 config integrity verification at startup
- Routes inference across 8 cloud providers and local Ollama, with 27 model routes and automatic failover
- Provides stub images for testing on restricted/air-gapped networks
- Includes a provider test harness (25 checks) and standalone E2E scripts

## How it differs from NemoClaw

| Aspect | NemoClaw (upstream) | nclawzero |
|--------|-------------------|-----------|
| Agent runtime | OpenClaw (Node/TypeScript) | ZeroClaw (Rust) |
| Config format | JSON | TOML (ZeroClaw native) |
| Gateway port | 18789 | 42617 |
| WASM plugin | None | Rust/Extism PDK compiled at image build time |
| Provider routing | Single provider | 27 routes across 8 providers with failover |
| Test harness | Brev-only E2E | Standalone E2E + 25-check provider harness + deploy-to-any-target script |
| Stub images | None | Full offline testing support for air-gapped networks |

## Requirements

### Minimum Hardware

| Resource | Cloud-Only (no GPU) | Local Inference (GPU) |
|----------|--------------------|-----------------------|
| GPU | None | 8 GB VRAM (Gemma4 E2B) or 12 GB VRAM (Gemma4 E4B) |
| CPU | 2 vCPU | 4 vCPU |
| RAM | 2 GB | 4 GB |
| Disk | 5 GB | 15-20 GB (includes model weights) |

### Software

| Dependency | Tested Version | Required For |
|------------|---------------|--------------|
| ZeroClaw | 0.6.9 | Downloaded from GitHub Releases at image build time |
| Docker | 29.3.1 | Building and running the container image |
| Node.js | v22 | Config generation during image build |
| Ollama | 0.20.7 | Local model inference only (optional) |
| Rust | 1.87 | WASM plugin compile inside Docker build (not needed on host) |

## Getting Started

### Build the ZeroClaw sandbox image

```bash
git clone --branch nemoclawzero root@192.168.207.101:/mnt/datapool/git/nclawzero.git
cd nclawzero

# Build the base image (downloads ZeroClaw v0.6.9 binary)
docker build -f agents/zeroclaw/Dockerfile.base -t zeroclaw-sandbox-base:latest .

# Build the sandbox image (compiles Rust WASM plugin — ~10 min first run)
docker build -f agents/zeroclaw/Dockerfile \
  --build-arg BASE_IMAGE=zeroclaw-sandbox-base:latest \
  -t zeroclaw-sandbox:latest .
```

### Run the container

```bash
docker run -d \
  --name zeroclaw \
  --network host \
  --entrypoint /usr/local/bin/nemoclaw-start \
  -e TOGETHER_API_KEY="your-key" \
  zeroclaw-sandbox:latest

# Verify
curl http://localhost:42617/health
```

### Run tests

```bash
# Unit tests (1540 passing)
npm install && cd nemoclaw && npm install && npm run build && cd ..
npm test

# Provider test harness (25 checks)
source ~/.zeroclaw/.env
zeroclaw gateway start &
scripts/zeroclaw-provider-harness.sh

# Standalone E2E
scripts/zeroclaw-e2e.sh --repo .

# Deploy to any test target (SSH, Brev, or local)
scripts/deploy-test-target.sh --local --stub          # stub mode, no network
scripts/deploy-test-target.sh --ssh user@host          # remote target
scripts/deploy-test-target.sh --brev instance-name     # Brev cloud
```

## Test Results

25/25 checks passed on the provider test harness. 1540/1540 unit tests passing.

### Provider Test Matrix

| Provider | Model Tested | Result |
|----------|-------------|--------|
| Together AI | meta-llama/Llama-3.3-70B-Instruct-Turbo | Pass |
| Groq | llama-3.3-70b-versatile | Pass |
| xAI (Grok) | grok-4-1-fast-non-reasoning | Pass |
| OpenAI | gpt-4.1-nano | Pass |
| NVIDIA NIM | meta/llama-4-maverick-17b-128e-instruct | Pass |
| Perplexity | sonar-pro | Pass |
| Google Gemini | gemini-2.0-flash | Pass |
| Ollama (local) | gemma4-e4b-opt | Pass |

## Model Routes

27 routes across 8 providers. Default: Together AI / MiniMax-M2.7.

| Provider | Models |
|----------|--------|
| Groq | Llama 3.3 70B, Llama 4 Scout, Qwen3 32B, GPT-OSS 120B/20B |
| Together AI | Llama 4 Maverick, Llama 3.3 70B Turbo, Qwen3 235B, Kimi K2.5, MiniMax M2.7, GLM-5 |
| xAI | Grok 4.20 Reasoning/Non-Reasoning/Multi-Agent, Grok 4.1 Fast |
| OpenAI | GPT-5.4, GPT-5.3, GPT-4.1 Nano |
| NVIDIA NIM | Llama 4 Maverick 128E |
| Perplexity | Sonar Pro |
| Google Gemini | Gemini 3 Flash, Gemini 3.1 Flash Lite, Gemini 3.1 Pro |
| Ollama (local) | Gemma4 E4B Opt, Gemma4 Consult |

## Project Structure

```text
nclawzero/
├── agents/zeroclaw/         # ZeroClaw agent integration
│   ├── Dockerfile.base      # Base image (ZeroClaw binary + gosu + node:22-slim)
│   ├── Dockerfile           # Sandbox image (WASM compile + config generation)
│   ├── Dockerfile.stub*     # Stub images for air-gapped testing
│   ├── start.sh             # Container entrypoint (config integrity, privilege separation)
│   ├── generate-config.ts   # TOML config generation from build args
│   ├── plugin/              # Rust WASM plugin source (Extism PDK)
│   └── stub/                # Stub binaries for offline testing
├── scripts/
│   ├── zeroclaw-e2e.sh              # Standalone E2E validation
│   ├── zeroclaw-provider-harness.sh # Provider + integration test harness
│   ├── deploy-test-target.sh        # Deploy & test on any target (SSH/Brev/local)
│   └── build-stub-images.sh         # Stub image builder for air-gapped networks
├── src/lib/                 # CLI (ZeroClaw-aware agent routing)
├── nemoclaw/                # Plugin (TypeScript)
├── test/                    # Integration and E2E tests
└── docs/                    # User-facing docs (Sphinx/MyST)
```

## Origin

This project is a fork of [NVIDIA NemoClaw](https://github.com/NVIDIA/NemoClaw) (Apache 2.0). The original NemoClaw provides CLI tooling and a blueprint for running OpenClaw agents inside OpenShell sandboxes. nclawzero replaces OpenClaw with ZeroClaw and adds independent provider routing, test harnesses, and container tooling. The upstream NemoClaw conventions (Conventional Commits, SPDX headers, prek hooks) are preserved.

## License

Apache 2.0. See [LICENSE](LICENSE).
