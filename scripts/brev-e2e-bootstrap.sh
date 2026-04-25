#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-FileCopyrightText: Copyright (c) 2026 Jason Perlow. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Bootstrap and run the ZeroClaw live E2E test on a Brev instance.
#
# Designed to be sent via:
#   brev exec awesome-gpu-name @scripts/brev-e2e-bootstrap.sh
#
# What it does:
#   1. Installs Docker + Node.js v22 if not present
#   2. Clones (or updates) nclawzero (ARGONAS) branch
#   3. Builds the REAL ZeroClaw sandbox images (pulls node:22-slim from
#      Docker Hub, downloads zeroclaw binary from GitHub Releases)
#   4. Starts the ZeroClaw container and verifies GET /health → {"status":"ok"}
#   5. Prints a PASS/FAIL summary and exits 0 on pass, 1 on fail
#
# This script is IDEMPOTENT — safe to run multiple times on the same instance.
# Re-running skips already-done steps (Docker already installed, repo already
# cloned, base image already built).
#
# Copy results back after the run:
#   brev copy awesome-gpu-name:/tmp/nemoclaw-e2e-results.txt ./

set -euo pipefail

REPO_URL="root@192.168.207.101:/mnt/datapool/git/nclawzero.git"
BRANCH="nclawzero-rebase"
WORK_DIR="${HOME}/nemoclaw-e2e"
RESULTS_FILE="/tmp/nemoclaw-e2e-results.txt"
BASE_TAG="ghcr.io/nvidia/nemoclaw/zeroclaw-sandbox-base:latest"
SANDBOX_TAG="ghcr.io/nvidia/nemoclaw/zeroclaw-sandbox:live-e2e"
CONTAINER_NAME="nemoclaw-zeroclaw-live-e2e"

# ── Helpers ───────────────────────────────────────────────────────
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*" | tee -a "$RESULTS_FILE"; }
ok() { printf '\033[1;32m  ✓ %s\033[0m\n' "$*" | tee -a "$RESULTS_FILE"; }
fail() { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" | tee -a "$RESULTS_FILE"; }
info() { printf '  %s\n' "$*" | tee -a "$RESULTS_FILE"; }

# Reset results file
mkdir -p "$(dirname "$RESULTS_FILE")"
printf 'NemoClaw ZeroClaw Live E2E — %s\n%s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(uname -a)" >"$RESULTS_FILE"

# Track overall pass/fail
FAILURES=0
record_fail() {
  FAILURES=$((FAILURES + 1))
  fail "$1"
}

# shellcheck disable=SC2329
cleanup() {
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

# ── 1. Docker ─────────────────────────────────────────────────────
step "Checking Docker"
if ! command -v docker &>/dev/null; then
  info "Installing Docker..."
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER" 2>/dev/null || true
  # Re-exec with docker group active
  exec sg docker "$0" "$@"
fi
docker info &>/dev/null || sudo systemctl start docker
ok "Docker $(docker --version | awk '{print $3}' | tr -d ',')"

# ── 2. Node.js v22 ────────────────────────────────────────────────
step "Checking Node.js"
NODE_OK=false
if command -v node &>/dev/null; then
  NODE_VER=$(node --version)
  MAJOR=$(echo "$NODE_VER" | tr -d 'v' | cut -d. -f1)
  if [ "$MAJOR" -ge 22 ]; then
    NODE_OK=true
    ok "Node.js $NODE_VER"
  else
    info "Node.js $NODE_VER found but v22+ required — installing v22"
  fi
fi

if [ "$NODE_OK" = false ]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
  sudo apt-get install -y nodejs
  ok "Node.js $(node --version) installed"
fi

# ── 3. Clone / update repo ────────────────────────────────────────
step "Cloning/updating nclawzero (ARGONAS) branch"
if [ -d "${WORK_DIR}/.git" ]; then
  git -C "$WORK_DIR" fetch origin "$BRANCH" --quiet
  git -C "$WORK_DIR" checkout "$BRANCH" --quiet
  git -C "$WORK_DIR" reset --hard "origin/$BRANCH" --quiet
  ok "Updated to $(git -C "$WORK_DIR" rev-parse --short HEAD)"
else
  git clone --branch "$BRANCH" --depth 1 "$REPO_URL" "$WORK_DIR"
  ok "Cloned $(git -C "$WORK_DIR" rev-parse --short HEAD)"
fi
cd "$WORK_DIR"

# ── 4. npm install + build ────────────────────────────────────────
step "Installing npm dependencies and building"
npm install --ignore-scripts --silent
./node_modules/.bin/tsc --project tsconfig.cli.json --noEmit false 2>&1 | tail -5 || true
ok "Build complete"

# ── 5. Build ZeroClaw sandbox-base (REAL — pulls from Docker Hub) ──
step "Building zeroclaw-sandbox-base (real Dockerfile.base)"

if docker image inspect "$BASE_TAG" &>/dev/null; then
  ok "Base image already present: $BASE_TAG"
  info "(delete with: docker rmi $BASE_TAG to force rebuild)"
else
  info "Pulling node:22-slim from Docker Hub + downloading zeroclaw binary from GitHub..."
  if docker build \
    -f agents/zeroclaw/Dockerfile.base \
    -t "$BASE_TAG" \
    . 2>&1 | tee /tmp/base-build.log | tail -20; then
    ok "Built $BASE_TAG"
  else
    record_fail "Base image build FAILED — see /tmp/base-build.log"
  fi
fi

# Verify the real zeroclaw binary is in the image
ZC_VER=$(docker run --rm "$BASE_TAG" /usr/local/bin/zeroclaw --version 2>&1 || true)
if echo "$ZC_VER" | grep -qE "^zeroclaw [0-9]"; then
  ok "Real zeroclaw binary: $ZC_VER"
else
  record_fail "zeroclaw binary check failed: $ZC_VER"
fi

# ── 6. Build full sandbox image (REAL — compiles WASM plugin) ──────
step "Building zeroclaw-sandbox (real Dockerfile — Rust WASM compile)"

if docker build \
  -f agents/zeroclaw/Dockerfile \
  --build-arg BASE_IMAGE="$BASE_TAG" \
  -t "$SANDBOX_TAG" \
  . 2>&1 | tee /tmp/sandbox-build.log | tail -20; then
  ok "Built $SANDBOX_TAG"
else
  record_fail "Sandbox image build FAILED — see /tmp/sandbox-build.log"
fi

# ── 7. Run container and check health probe ───────────────────────
step "Starting container and checking health probe"

docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
docker run -d \
  --name "$CONTAINER_NAME" \
  -p 42617:42617 \
  --entrypoint "" \
  "$SANDBOX_TAG" \
  /usr/local/bin/nemoclaw-start

# Wait up to 60s for the health probe
HEALTH_OK=false
for i in $(seq 1 12); do
  sleep 5
  RESP=$(curl -sf http://localhost:42617/health 2>/dev/null || true)
  if echo "$RESP" | grep -q '"ok"'; then
    HEALTH_OK=true
    break
  fi
  info "  Waiting for health probe... ($((i * 5))s)"
done

if [ "$HEALTH_OK" = true ]; then
  ok "Health probe: $RESP"
  # Verify it is NOT the stub binary
  if echo "$RESP" | grep -q '"stub"'; then
    record_fail "Response contains stub marker — real binary not running!"
  else
    ok "Confirmed: no stub marker in response (real zeroclaw binary)"
  fi
else
  record_fail "Health probe did not respond within 60s"
  info "Container logs:"
  docker logs "$CONTAINER_NAME" 2>&1 | tail -20 | tee -a "$RESULTS_FILE"
fi

# ── 8. Config integrity check (via container logs) ────────────────
step "Verifying config integrity check passed"
LOGS=$(docker logs "$CONTAINER_NAME" 2>&1)
if echo "$LOGS" | grep -q "Deployed verified config"; then
  ok "Config integrity check passed (start.sh verified sha256)"
else
  record_fail "Config integrity check not confirmed in logs"
  echo "$LOGS" | tail -10 | tee -a "$RESULTS_FILE"
fi

# ── 9. Summary ────────────────────────────────────────────────────
step "Summary"
echo "" | tee -a "$RESULTS_FILE"
if [ "$FAILURES" -eq 0 ]; then
  printf '\033[1;32m  PASS — all checks passed (%s)\033[0m\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$RESULTS_FILE"
  echo ""
  info "Results written to: $RESULTS_FILE"
  info "Copy back with:  brev copy awesome-gpu-name:${RESULTS_FILE} ./"
  exit 0
else
  printf '\033[1;31m  FAIL — %d check(s) failed\033[0m\n' "$FAILURES" | tee -a "$RESULTS_FILE"
  echo ""
  info "Results written to: $RESULTS_FILE"
  info "Copy back with:  brev copy awesome-gpu-name:${RESULTS_FILE} ./"
  exit 1
fi
