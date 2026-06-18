#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-FileCopyrightText: Copyright (c) 2026 Jason Perlow. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# ZeroClaw Live E2E Test — standalone, no brev CLI required.
#
# Runs on any Linux x86_64/arm64 system with internet access to:
#   - Docker Hub  (node:22-slim, rust:1.87-bookworm)
#   - GitHub Releases CDN  (zeroclaw binary, gosu binary)
#   - api.github.com  (repo clone, if not using --repo)
#
# Usage:
#   scripts/zeroclaw-e2e.sh [OPTIONS]
#
# Options:
#   --repo PATH      Path to an existing local nemoclaw checkout (skips git clone)
#   --token TOKEN    GitHub PAT for private repo access
#   --work-dir PATH  Working directory for clone (default: ~/zeroclaw-e2e)
#   --results PATH   Results file path (default: /tmp/zeroclaw-e2e-results.txt)
#
# One-liner (fresh system, public repo):
#   bash <(curl -fsSL scripts/zeroclaw-e2e.sh (from ARGONAS clone))
#
# From a local checkout:
#   scripts/zeroclaw-e2e.sh --repo /path/to/nemoclaw
#
# This script is IDEMPOTENT — rerunning skips steps that are already done
# (Docker installed, repo cloned, base image built with Docker layer cache).

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────
REPO_URL="root@10.0.0.101:/mnt/datapool/git/nclawzero.git"
BRANCH="nclawzero-rebase"
REPO_PATH=""    # set via --repo; empty means clone
GITHUB_TOKEN="" # set via --token; needed for private repos
WORK_DIR="${HOME}/zeroclaw-e2e"
RESULTS_FILE="/tmp/zeroclaw-e2e-results.txt"

BASE_TAG="ghcr.io/nvidia/nemoclaw/zeroclaw-sandbox-base:latest"
SANDBOX_TAG="ghcr.io/nvidia/nemoclaw/zeroclaw-sandbox:e2e"
CONTAINER_NAME="nemoclaw-zeroclaw-e2e"

# ── Argument parsing ──────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO_PATH="$2"
      shift 2
      ;;
    --token)
      GITHUB_TOKEN="$2"
      shift 2
      ;;
    --work-dir)
      WORK_DIR="$2"
      shift 2
      ;;
    --results)
      RESULTS_FILE="$2"
      shift 2
      ;;
    -h | --help)
      sed -n '/^# Usage/,/^[^#]/p' "$0" | head -20 | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*" | tee -a "$RESULTS_FILE"; }
ok() { printf '\033[1;32m  ✓ %s\033[0m\n' "$*" | tee -a "$RESULTS_FILE"; }
fail() { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" | tee -a "$RESULTS_FILE"; }
info() { printf '  %s\n' "$*" | tee -a "$RESULTS_FILE"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*" | tee -a "$RESULTS_FILE"; }

mkdir -p "$(dirname "$RESULTS_FILE")"
printf 'NemoClaw ZeroClaw Standalone E2E — %s\n%s\n\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(uname -a)" >"$RESULTS_FILE"

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

# ── 1. Preflight: network connectivity ───────────────────────────
step "Preflight: checking internet connectivity"

NET_OK=true
for check in \
  "Docker Hub|https://registry-1.docker.io/v2/" \
  "GitHub Releases CDN|https://github.com/zeroclaw-labs/zeroclaw/releases" \
  "GitHub API|https://api.github.com"; do
  label="${check%%|*}"
  url="${check##*|}"
  if curl -sfI --max-time 10 "$url" >/dev/null 2>&1; then
    ok "$label reachable"
  else
    fail "$label NOT reachable ($url)"
    NET_OK=false
  fi
done

if [ "$NET_OK" = false ]; then
  fail "One or more required endpoints are blocked."
  info "This script requires full internet access."
  info "If you are on a restricted network (e.g. OmniStation/corpnet),"
  info "use the stub-based local test instead:"
  info "  scripts/build-stub-images.sh && nemoclaw onboard --agent zeroclaw"
  exit 1
fi

# ── 2. GPU detection (informational) ─────────────────────────────
step "GPU detection"
if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
  GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "unknown")
  ok "GPU detected: $GPU_NAME"
else
  warn "No NVIDIA GPU detected — health probe test does not require a GPU"
fi

# ── 3. Docker ─────────────────────────────────────────────────────
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

# ── 4. Node.js v22 ────────────────────────────────────────────────
step "Checking Node.js"
NODE_OK=false
if command -v node &>/dev/null; then
  NODE_VER=$(node --version)
  MAJOR=$(echo "$NODE_VER" | tr -d 'v' | cut -d. -f1)
  if [ "$MAJOR" -ge 22 ]; then
    NODE_OK=true
    ok "Node.js $NODE_VER"
  else
    info "Node.js $NODE_VER found but v22+ required — upgrading"
  fi
fi
if [ "$NODE_OK" = false ]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
  sudo apt-get install -y nodejs
  ok "Node.js $(node --version) installed"
fi

# ── 5. Repo: use local checkout or clone ─────────────────────────
step "Preparing repo"
if [ -n "$REPO_PATH" ]; then
  if [ -d "${REPO_PATH}/.git" ] || [ -d "${REPO_PATH}/agents/zeroclaw" ]; then
    ok "Using local repo: $REPO_PATH"
  else
    record_fail "Path does not look like a nemoclaw checkout: $REPO_PATH"
    exit 1
  fi
  WORK_DIR="$REPO_PATH"
else
  # Set auth header if token provided
  CLONE_URL="$REPO_URL"
  if [ -n "$GITHUB_TOKEN" ]; then
    CLONE_URL="root@10.0.0.101:/mnt/datapool/git/nclawzero.git"
  fi

  if [ -d "${WORK_DIR}/.git" ]; then
    info "Updating existing clone at $WORK_DIR..."
    git -C "$WORK_DIR" fetch origin "$BRANCH" --quiet
    git -C "$WORK_DIR" checkout "$BRANCH" --quiet
    git -C "$WORK_DIR" reset --hard "origin/$BRANCH" --quiet
    ok "Updated to $(git -C "$WORK_DIR" rev-parse --short HEAD)"
  else
    git clone --branch "$BRANCH" --depth 1 "$CLONE_URL" "$WORK_DIR"
    ok "Cloned $(git -C "$WORK_DIR" rev-parse --short HEAD)"
  fi
fi
cd "$WORK_DIR"

# ── 6. npm install + TypeScript build ────────────────────────────
step "Installing npm deps and building"
npm install --ignore-scripts --silent
./node_modules/.bin/tsc --project tsconfig.cli.json --noEmit false 2>&1 | tail -5 || true
ok "Build complete"

# ── 7. Build zeroclaw-sandbox-base (REAL Dockerfile.base) ────────
step "Building zeroclaw-sandbox-base (pulls from Docker Hub + GitHub Releases)"

if docker image inspect "$BASE_TAG" &>/dev/null; then
  ok "Base image already present: $BASE_TAG"
  info "(delete with: docker rmi $BASE_TAG  to force a rebuild)"
else
  info "Pulling node:22-slim from Docker Hub..."
  info "Downloading zeroclaw binary from GitHub Releases..."
  if docker build \
    -f agents/zeroclaw/Dockerfile.base \
    -t "$BASE_TAG" \
    . 2>&1 | tee /tmp/zeroclaw-base-build.log | tail -20; then
    ok "Built $BASE_TAG"
  else
    record_fail "Base image build FAILED — see /tmp/zeroclaw-base-build.log"
  fi
fi

# Verify real zeroclaw binary is present and executable
ZC_VER=$(docker run --rm "$BASE_TAG" /usr/local/bin/zeroclaw --version 2>&1 || true)
if echo "$ZC_VER" | grep -qE "^zeroclaw [0-9]"; then
  ok "Real zeroclaw binary: $ZC_VER"
else
  record_fail "zeroclaw binary check failed: $ZC_VER"
fi

# ── 8. Build zeroclaw-sandbox (REAL Dockerfile — Rust WASM) ──────
step "Building zeroclaw-sandbox (compiles WASM plugin via rust:1.87-bookworm)"
info "This stage pulls rust:1.87-bookworm and compiles the WASM plugin."
info "First run: 10-20 min. Subsequent runs use Docker layer cache."

if docker build \
  -f agents/zeroclaw/Dockerfile \
  --build-arg BASE_IMAGE="$BASE_TAG" \
  -t "$SANDBOX_TAG" \
  . 2>&1 | tee /tmp/zeroclaw-sandbox-build.log | tail -20; then
  ok "Built $SANDBOX_TAG"
else
  record_fail "Sandbox image build FAILED — see /tmp/zeroclaw-sandbox-build.log"
fi

# Confirm no stub label on the final image
if docker inspect "$SANDBOX_TAG" 2>/dev/null \
  | python3 -c "import json,sys; labels=json.load(sys.stdin)[0].get('Config',{}).get('Labels',{}); exit(0 if labels.get('io.nemoclaw.stub')=='true' else 1)" \
    2>/dev/null; then
  record_fail "Final image carries io.nemoclaw.stub=true — this is a stub image, not a real build"
else
  ok "Confirmed: io.nemoclaw.stub label not present (real build)"
fi

# ── 9. Start container and check health probe ─────────────────────
step "Starting container and checking health probe"

docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
docker run -d \
  --name "$CONTAINER_NAME" \
  -p 42617:42617 \
  --entrypoint "" \
  "$SANDBOX_TAG" \
  /usr/local/bin/nemoclaw-start

# Wait up to 60 s for the health probe
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

# ── 10. Config integrity check ────────────────────────────────────
step "Verifying config integrity check"
LOGS=$(docker logs "$CONTAINER_NAME" 2>&1)
if echo "$LOGS" | grep -q "Deployed verified config"; then
  ok "Config integrity check passed (start.sh verified sha256)"
else
  record_fail "Config integrity check not confirmed in logs"
  echo "$LOGS" | tail -10 | tee -a "$RESULTS_FILE"
fi

# ── 11. Summary ───────────────────────────────────────────────────
step "Summary"
echo "" | tee -a "$RESULTS_FILE"
if [ "$FAILURES" -eq 0 ]; then
  printf '\033[1;32m  PASS — all checks passed (%s)\033[0m\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$RESULTS_FILE"
  echo ""
  info "Results written to: $RESULTS_FILE"
  exit 0
else
  printf '\033[1;31m  FAIL — %d check(s) failed\033[0m\n' "$FAILURES" | tee -a "$RESULTS_FILE"
  echo ""
  info "Results written to: $RESULTS_FILE"
  exit 1
fi
