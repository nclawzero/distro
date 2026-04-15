---
name: "nclawzero-skills-guide"
description: "Skills catalog for nclawzero. Lists all nclawzero-specific skills and references the upstream nemoclaw-* skills. Use when discovering nclawzero capabilities, choosing the right skill, or orienting in the project. Trigger keywords - skills, capabilities, what can I do, help, guide, index, overview, start here, nclawzero."
---

<!-- SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved. -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- SPDX-FileCopyrightText: Copyright (c) 2026 Jason Perlow. All rights reserved. -->

# nclawzero Skills Guide

nclawzero is a research project exploring ZeroClaw agents inside OpenShell sandboxes on memory-constrained and resource-constrained devices for edge and embedded deployments. Forked from NVIDIA NemoClaw but independently maintained.

This guide lists every agent skill specific to nclawzero and references the upstream NemoClaw skills that also apply.

## nclawzero Skills

Skills prefixed with `nclawzero-` cover ZeroClaw-specific workflows, configuration, security, and testing for edge deployments.

| Skill | Summary |
|-------|---------|
| `nclawzero-zeroclaw-get-started` | Install ZeroClaw v0.6.9 on Pi/ARM64, create config.toml, set API keys, start the gateway daemon, verify health, access the dashboard, and run the first inference. |
| `nclawzero-zeroclaw-config` | ZeroClaw TOML configuration reference: provider setup (Together AI, Groq, NVIDIA, OpenAI, xAI, Perplexity, Gemini, Ollama), model routes, gateway settings, and NVIDIA inference proxy model names. |
| `nclawzero-zeroclaw-security` | Security hardening for ZeroClaw containers: privilege separation (gosu, gateway user), capability drops, config integrity verification (sha256sum), symlink validation, network policies, and .env permissions. |
| `nclawzero-testing` | Testing guide: unit tests (Vitest, 1700+ tests), shard-based test harness, E2E tests, deploy scripts, and Pi test targets (zeropi, clawpi). |
| `nclawzero-skills-guide` | This skill. Skills catalog and orientation guide. |

## Choosing a Skill

| Task | Use This Skill |
|------|---------------|
| First time setting up ZeroClaw | `nclawzero-zeroclaw-get-started` |
| Changing inference provider or model | `nclawzero-zeroclaw-config` |
| Reviewing container security controls | `nclawzero-zeroclaw-security` |
| Running or analyzing tests | `nclawzero-testing` |
| Figuring out which skill to use | `nclawzero-skills-guide` |

## Upstream NemoClaw Skills

nclawzero inherits all upstream `nemoclaw-*` skills from the NemoClaw project. These cover the broader NemoClaw ecosystem (OpenClaw agents, OpenShell sandboxes, Nemotron inference, and project maintenance).

### User Skills (`nemoclaw-user-*`)

| Skill | Summary |
|-------|---------|
| `nemoclaw-user-overview` | What NemoClaw is, ecosystem placement, how it works, and release notes. |
| `nemoclaw-user-get-started` | Install NemoClaw, launch a sandbox, and run the first agent prompt. |
| `nemoclaw-user-configure-inference` | Choose and switch inference providers, set up local inference servers. |
| `nemoclaw-user-manage-policy` | Approve or deny blocked egress requests, customize network policy. |
| `nemoclaw-user-monitor-sandbox` | Check sandbox health, read logs, trace agent behavior. |
| `nemoclaw-user-deploy-remote` | Deploy to a remote GPU instance, set up Telegram, review container hardening. |
| `nemoclaw-user-configure-security` | Risk framework for security controls, credential storage, posture trade-offs. |
| `nemoclaw-user-workspace` | Back up and restore OpenClaw workspace files across sandbox restarts. |
| `nemoclaw-user-reference` | CLI command reference, plugin architecture, baseline policies, troubleshooting. |

### Maintainer Skills (`nemoclaw-maintainer-*`)

| Skill | Summary |
|-------|---------|
| `nemoclaw-maintainer-morning` | Morning standup: triage backlog, determine target version, output daily plan. |
| `nemoclaw-maintainer-day` | Daytime loop: pick highest-value item and execute the right workflow. |
| `nemoclaw-maintainer-evening` | End-of-day handoff: check progress, bump stragglers, generate QA summary. |
| `nemoclaw-maintainer-cut-release-tag` | Cut an annotated semver tag on main and push. |
| `nemoclaw-maintainer-find-review-pr` | Find open PRs labeled security + priority-high for review. |
| `nemoclaw-maintainer-security-code-review` | 9-category security review with per-category PASS/WARNING/FAIL verdicts. |

### Contributor Skills (`nemoclaw-contributor-*`)

| Skill | Summary |
|-------|---------|
| `nemoclaw-contributor-update-docs` | Scan recent commits for user-facing changes and draft documentation updates. |

## Getting Started

For nclawzero-specific work (ZeroClaw on edge devices), start with `nclawzero-zeroclaw-get-started`.

For general NemoClaw work (OpenClaw agents, sandbox management), start with `nemoclaw-user-get-started` or load `nemoclaw-skills-guide` for the full upstream catalog.

## Related Skills

- `nemoclaw-skills-guide` — Full upstream NemoClaw skills catalog
