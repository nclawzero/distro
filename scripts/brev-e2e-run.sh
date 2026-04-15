#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-FileCopyrightText: Copyright (c) 2026 Jason Perlow. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Invoke the ZeroClaw live E2E test on a Brev instance from OmniStation.
#
# Usage:
#   scripts/brev-e2e-run.sh [instance-name]
#
# Defaults to "awesome-gpu-name" if no argument given.
#
# What it does:
#   1. Checks the instance is RUNNING (starts it if STOPPED)
#   2. Sends scripts/brev-e2e-bootstrap.sh to the instance via `brev exec`
#   3. Waits for the test to complete
#   4. Copies /tmp/nemoclaw-e2e-results.txt back to ./e2e-results/
#   5. Exits with the remote test exit code
#
# Run from the nemoclaw repo root:
#   export PATH="$HOME/.local/bin:$PATH"   # brev CLI location
#   scripts/brev-e2e-run.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

INSTANCE="${1:-awesome-gpu-name}"
RESULTS_REMOTE="/tmp/nemoclaw-e2e-results.txt"
RESULTS_LOCAL="${REPO_ROOT}/e2e-results"

export PATH="$HOME/.local/bin:$PATH" # brev CLI

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*" >&2; }
ok() { printf '\033[1;32m  ✓ %s\033[0m\n' "$*" >&2; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*" >&2; }
die() {
  printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2
  exit 1
}

# ── 1. Check instance status ──────────────────────────────────────
step "Checking instance: $INSTANCE"

STATUS=$(brev ls 2>&1 | grep "$INSTANCE" | awk '{print $2}' || true)
if [ -z "$STATUS" ]; then
  die "Instance '$INSTANCE' not found. Run: brev ls"
fi
echo "  Current status: $STATUS" >&2

if [ "$STATUS" = "STOPPED" ]; then
  warn "Instance is STOPPED — attempting to start..."
  brev start "$INSTANCE" &
  START_PID=$!
  for i in $(seq 1 20); do
    sleep 15
    STATUS=$(brev ls 2>&1 | grep "$INSTANCE" | awk '{print $2}' || true)
    echo "  Status: $STATUS (${i}x15s)" >&2
    if [ "$STATUS" = "RUNNING" ]; then break; fi
  done
  wait "$START_PID" 2>/dev/null || true
fi

if [ "$STATUS" != "RUNNING" ]; then
  die "Instance is $STATUS (not RUNNING). Start it from https://brev.nvidia.com and re-run."
fi
ok "Instance RUNNING"

# ── 2. Send and run bootstrap script ─────────────────────────────
step "Running brev-e2e-bootstrap.sh on $INSTANCE"
echo "  This will build real Docker images (node:22-slim + zeroclaw binary)." >&2
echo "  Expect 10-20 minutes for first run; subsequent runs skip cached layers." >&2
echo "" >&2

brev exec "$INSTANCE" @"${SCRIPT_DIR}/brev-e2e-bootstrap.sh"
REMOTE_EXIT=$?

# ── 3. Copy results back ──────────────────────────────────────────
step "Copying results back"
mkdir -p "$RESULTS_LOCAL"
TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
LOCAL_FILE="${RESULTS_LOCAL}/e2e-${INSTANCE}-${TIMESTAMP}.txt"

# shellcheck disable=SC2015
brev copy "${INSTANCE}:${RESULTS_REMOTE}" "$LOCAL_FILE" 2>/dev/null \
  && ok "Results saved to: $LOCAL_FILE" \
  || warn "Could not copy results file (brev copy may not be supported — check stdout above)"

# ── 4. Exit with remote status ────────────────────────────────────
echo "" >&2
if [ "$REMOTE_EXIT" -eq 0 ]; then
  printf '\033[1;32m  LIVE E2E TEST PASSED\033[0m\n' >&2
else
  printf '\033[1;31m  LIVE E2E TEST FAILED (exit %d)\033[0m\n' "$REMOTE_EXIT" >&2
fi
exit "$REMOTE_EXIT"
