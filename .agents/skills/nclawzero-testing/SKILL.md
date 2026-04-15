---
name: "nclawzero-testing"
description: "Testing guide for nclawzero. Covers unit tests with Vitest (1700+ tests), the shard-based test harness for recording and querying results, E2E tests for ZeroClaw sandboxes, deploy scripts for test targets, and the Pi test target inventory. Use when running tests, diagnosing failures, recording test runs, or deploying to test targets."
---

<!-- SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved. -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- SPDX-FileCopyrightText: Copyright (c) 2026 Jason Perlow. All rights reserved. -->

# nclawzero Testing Guide

How to run, record, and analyze tests for nclawzero. Covers unit tests, the test harness, E2E tests, and test target deployment.

## Unit Tests

nclawzero has 1700+ unit and integration tests organized into three Vitest projects (defined in `vitest.config.ts`):

| Project | Scope | Path |
|---------|-------|------|
| `cli` | CLI integration tests | `test/**/*.test.{js,ts}` |
| `plugin` | Plugin unit tests (co-located) | `nemoclaw/src/**/*.test.ts` |
| `e2e-brev` | Cloud E2E (requires `BREV_API_TOKEN`) | `test/e2e/brev-e2e.test.js` |

### Running All Tests

```bash
npx vitest run
```

### Running a Specific Project

```bash
# CLI tests only
npx vitest run --project cli

# Plugin tests only
npx vitest run --project plugin
```

### Running a Single Test File

```bash
npx vitest run test/credentials.test.ts
```

### Watch Mode

```bash
npx vitest
```

## Test Harness

The test harness (`scripts/test-harness.py`) is a shard-based test result storage and query CLI, modeled after the MNEMOS memory management system. It records Vitest results as JSON shards and supports search, comparison, and trend analysis.

Storage location: `~/.nclawzero-harness/runs/`

### Recording a Test Run

```bash
python3 scripts/test-harness.py record
```

This runs the full test suite, captures the output, and stores results as a timestamped JSON shard.

Record a specific suite:

```bash
python3 scripts/test-harness.py record --suite cli
python3 scripts/test-harness.py record --suite plugin
```

### Querying Results

| Command | Description |
|---------|-------------|
| `python3 scripts/test-harness.py stats` | Summary across all recorded runs |
| `python3 scripts/test-harness.py recent 10` | Most recent 10 runs |
| `python3 scripts/test-harness.py failures` | Failures from the latest run |
| `python3 scripts/test-harness.py failures RUN_ID` | Failures from a specific run |
| `python3 scripts/test-harness.py flaky` | Detect flaky tests (intermittent pass/fail) |
| `python3 scripts/test-harness.py flaky 14` | Flaky tests over a 14-day window |
| `python3 scripts/test-harness.py compare RUN1 RUN2` | Diff two runs side by side |
| `python3 scripts/test-harness.py trend` | Pass rate trend over time |
| `python3 scripts/test-harness.py trend 30` | Pass rate trend over 30 days |
| `python3 scripts/test-harness.py search "credential"` | Search test names and error messages |
| `python3 scripts/test-harness.py get RUN_ID` | Full details of a specific run |

### Exporting and Maintenance

```bash
# Export all runs
python3 scripts/test-harness.py export json
python3 scripts/test-harness.py export csv
python3 scripts/test-harness.py export markdown

# Prune old runs
python3 scripts/test-harness.py prune 90    # Delete runs older than 90 days
```

## E2E Tests

### ZeroClaw E2E

The primary E2E test proves the complete ZeroClaw user journey: install, onboard with the zeroclaw agent, verify the sandbox, and run live inference.

```bash
NEMOCLAW_NON_INTERACTIVE=1 \
NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 \
NVIDIA_API_KEY=nvapi-... \
  bash test/e2e/test-zeroclaw-e2e.sh
```

Prerequisites:
- Docker running
- `NVIDIA_API_KEY` set (real key, starts with `nvapi-`)
- Network access to `integrate.api.nvidia.com`

### ZeroClaw Sandbox Operations

Tests gateway operations against a running ZeroClaw sandbox:

```bash
bash test/e2e/test-zeroclaw-sandbox-operations.sh
```

Test cases:
- `TC-ZSO-01` — Health probe (`/health`)
- `TC-ZSO-02` — API status (`/api/status`)
- `TC-ZSO-03` — Webhook inference (`/webhook`)
- `TC-ZSO-04` — Config reload after restart
- `TC-ZSO-05` — Gateway restart and recovery
- `TC-ZSO-06` — Dashboard accessible (`GET /`)

Environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `ZEROCLAW_HOST` | `localhost` | Gateway host |
| `ZEROCLAW_PORT` | `42617` | Gateway port |
| `NEMOCLAW_SANDBOX_NAME` | `e2e-zeroclaw` | Sandbox name |

### Stub-Based Testing (Offline)

For CDN-blocked networks (like NVIDIA OmniStation), use stub images:

```bash
# Build stub images (one-time)
scripts/build-stub-images.sh

# Run with stubs
nemoclaw onboard --agent zeroclaw

# Verify (stub marker present)
curl http://localhost:42617/health
# {"status":"ok","version":"0.6.9-stub","stub":true}
```

## Deploy Script

`scripts/deploy-test-target.sh` deploys and runs the ZeroClaw E2E suite on any test target. It installs Docker and Node.js if missing, clones or updates the repo, runs the full test suite, and copies results back.

### Targets

```bash
# SSH to a remote host
scripts/deploy-test-target.sh --ssh pi@192.168.207.56 --nvidia-key nvapi-xxx

# Brev cloud instance
scripts/deploy-test-target.sh --brev awesome-gpu-name --nvidia-key nvapi-xxx

# Local machine with live images
scripts/deploy-test-target.sh --local --nvidia-key nvapi-xxx

# Local machine with stub images (no network required)
scripts/deploy-test-target.sh --local --stub
```

### Options

| Flag | Description |
|------|-------------|
| `--ssh USER@HOST` | Deploy via SSH (key auth) |
| `--brev INSTANCE` | Deploy via Brev |
| `--local` | Run on this machine |
| `--token TOKEN` | GitHub PAT for private repo access |
| `--nvidia-key KEY` | NVIDIA API key for live inference |
| `--branch BRANCH` | Branch to test (default: `nemoclawzero`) |
| `--stub` | Use stub images (no Docker Hub required) |
| `--skip-install` | Skip Docker/Node install |
| `--keep` | Keep container after test |
| `-v, --verbose` | Print all remote output |

## Test Targets

nclawzero maintains Raspberry Pi test targets for edge validation:

| Target | IP | Role | Description |
|--------|-----|------|-------------|
| zeropi | 192.168.207.56 | Minimal footprint | ARM64 Pi for baseline resource testing |
| clawpi | 192.168.207.54 | Full-featured | ARM64 Pi for full ZeroClaw feature testing |

### Deploying to a Test Target

```bash
# Deploy to zeropi (minimal footprint)
scripts/deploy-test-target.sh --ssh pi@192.168.207.56 --nvidia-key nvapi-xxx

# Deploy to clawpi (full-featured)
scripts/deploy-test-target.sh --ssh pi@192.168.207.54 --nvidia-key nvapi-xxx
```

Results are written to `./e2e-results/` on the invoking machine (configurable with `--results-dir`).

## Repository Topology for Testing

```text
ARGONAS bare repo                    — LAN source of truth
  /mnt/datapool/git/nclawzero.git
     |
  zeropi (.56) ~/nclawzero           — min footprint test target
  clawpi (.54) ~/nclawzero           — full-featured test target
```

The deploy script clones from ARGONAS when deploying to Pi targets.

## Related Skills

- `nclawzero-zeroclaw-get-started` — Installation and first run
- `nclawzero-zeroclaw-config` — Configuration reference
- `nclawzero-zeroclaw-security` — Security hardening reference
- `nclawzero-skills-guide` — Skills catalog for nclawzero
