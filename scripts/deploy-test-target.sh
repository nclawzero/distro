#!/usr/bin/env bash
# shellcheck disable=SC2015
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-FileCopyrightText: Copyright (c) 2026 Jason Perlow. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Deploy & run ZeroClaw E2E on any test target.
#
# Replicates the Brev testing environment on any Linux x86_64/arm64 host.
# Works with SSH targets, Brev instances, or the local machine.
#
# What it does:
#   1. Connects to the target (or runs locally)
#   2. Installs Docker + Node.js 22 if missing
#   3. Clones/updates nclawzero (ARGONAS)
#   4. Runs the full ZeroClaw E2E test suite
#   5. Copies results back to the invoking machine
#
# Usage:
#   scripts/deploy-test-target.sh [OPTIONS]
#
# Targets (pick one):
#   --ssh USER@HOST       Deploy via SSH (key auth assumed)
#   --brev INSTANCE       Deploy via brev exec (must be registered)
#   --local               Run on this machine (no remote deploy)
#
# Options:
#   --token TOKEN         GitHub PAT (for private repo access)
#   --nvidia-key KEY      NVIDIA API key (nvapi-...) for live inference tests
#   --repo PATH           Use local checkout instead of cloning (--local mode only)
#   --branch BRANCH       Branch to test (default: nclawzero-rebase)
#   --results-dir DIR     Where to copy results locally (default: ./e2e-results/)
#   --skip-install        Skip Docker/Node install (target already provisioned)
#   --stub                Use stub images (no Docker Hub / GitHub Releases required)
#   --keep                Don't clean up container after test
#   -v, --verbose         Print all remote output to stdout
#   -h, --help            Show this help
#
# Examples:
#   # SSH to a cloud VM
#   scripts/deploy-test-target.sh --ssh ubuntu@10.0.0.5 --nvidia-key nvapi-xxx
#
#   # Brev instance
#   scripts/deploy-test-target.sh --brev awesome-gpu-name --nvidia-key nvapi-xxx
#
#   # Local machine (stub images, no network required)
#   scripts/deploy-test-target.sh --local --stub
#
#   # Local machine with live images
#   scripts/deploy-test-target.sh --local --nvidia-key nvapi-xxx
#
# This script is IDEMPOTENT — safe to rerun. Docker layer cache makes rebuilds fast.

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────
TARGET_MODE="" # ssh, brev, or local
SSH_TARGET=""
BREV_INSTANCE=""
GITHUB_TOKEN=""
NVIDIA_API_KEY=""
REPO_PATH=""
BRANCH="nclawzero-rebase"
RESULTS_DIR="./e2e-results"
SKIP_INSTALL=false
USE_STUB=false
KEEP_CONTAINER=false
VERBOSE=false

REPO_URL="root@10.0.0.101:/mnt/datapool/git/nclawzero.git"
REMOTE_WORK_DIR="\$HOME/nemoclaw-e2e"
REMOTE_RESULTS="/tmp/zeroclaw-e2e-results.txt"

# ── Argument parsing ─────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh)
      TARGET_MODE="ssh"
      SSH_TARGET="$2"
      shift 2
      ;;
    --brev)
      TARGET_MODE="brev"
      BREV_INSTANCE="$2"
      shift 2
      ;;
    --local)
      TARGET_MODE="local"
      shift
      ;;
    --token)
      GITHUB_TOKEN="$2"
      shift 2
      ;;
    --nvidia-key)
      NVIDIA_API_KEY="$2"
      shift 2
      ;;
    --repo)
      # shellcheck disable=SC2034
      REPO_PATH="$2"
      shift 2
      ;;
    --branch)
      BRANCH="$2"
      shift 2
      ;;
    --results-dir)
      RESULTS_DIR="$2"
      shift 2
      ;;
    --skip-install)
      SKIP_INSTALL=true
      shift
      ;;
    --stub)
      USE_STUB=true
      shift
      ;;
    --keep)
      KEEP_CONTAINER=true
      shift
      ;;
    -v | --verbose)
      VERBOSE=true
      shift
      ;;
    -h | --help)
      sed -n '/^# Usage/,/^[^#]/p' "$0" | head -40 | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$TARGET_MODE" ]]; then
  echo "Error: specify a target with --ssh USER@HOST, --brev INSTANCE, or --local" >&2
  exit 1
fi

# ── Helpers ──────────────────────────────────────────────────────────
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok() { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m  ✗ %s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }

# Run a command on the target
run_remote() {
  local cmd="$1"
  case "$TARGET_MODE" in
    ssh)
      if $VERBOSE; then
        ssh -o StrictHostKeyChecking=accept-new "$SSH_TARGET" "bash -lc '$cmd'"
      else
        ssh -o StrictHostKeyChecking=accept-new "$SSH_TARGET" "bash -lc '$cmd'" 2>&1
      fi
      ;;
    brev)
      if $VERBOSE; then
        brev exec "$BREV_INSTANCE" -- bash -lc "$cmd"
      else
        brev exec "$BREV_INSTANCE" -- bash -lc "$cmd" 2>&1
      fi
      ;;
    local)
      if $VERBOSE; then
        bash -lc "$cmd"
      else
        bash -lc "$cmd" 2>&1
      fi
      ;;
  esac
}

# Copy file from target to local
copy_from_target() {
  local remote_path="$1" local_path="$2"
  mkdir -p "$(dirname "$local_path")"
  case "$TARGET_MODE" in
    ssh) scp "$SSH_TARGET:$remote_path" "$local_path" ;;
    brev) brev copy "$BREV_INSTANCE:$remote_path" "$local_path" ;;
    local) cp "$remote_path" "$local_path" ;;
  esac
}

# ── 1. Provision target ─────────────────────────────────────────────
if ! $SKIP_INSTALL; then
  step "Provisioning target: installing Docker and Node.js 22"

  run_remote "$(
    cat <<'PROVISION'
set -euo pipefail

# Docker
if ! command -v docker &>/dev/null; then
  echo "Installing Docker..."
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER" 2>/dev/null || true
  echo "Docker installed. You may need to re-login for group membership."
fi
docker --version

# Node.js 22
NODE_MAJOR=22
if ! command -v node &>/dev/null || [[ "$(node --version | cut -d. -f1 | tr -d v)" -lt "$NODE_MAJOR" ]]; then
  echo "Installing Node.js ${NODE_MAJOR}..."
  if command -v apt-get &>/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | sudo -E bash -
    sudo apt-get install -y nodejs
  elif command -v dnf &>/dev/null; then
    curl -fsSL https://rpm.nodesource.com/setup_${NODE_MAJOR}.x | sudo -E bash -
    sudo dnf install -y nodejs
  else
    echo "Unsupported package manager. Install Node.js $NODE_MAJOR manually."
    exit 1
  fi
fi
node --version
npm --version

# Git
if ! command -v git &>/dev/null; then
  echo "Installing git..."
  sudo apt-get install -y git 2>/dev/null || sudo dnf install -y git 2>/dev/null
fi
git --version

echo "Provisioning complete."
PROVISION
  )" && ok "Target provisioned" || {
    fail "Provisioning failed"
    exit 1
  }
else
  step "Skipping provisioning (--skip-install)"
fi

# ── 2. Clone / update repo ──────────────────────────────────────────
step "Setting up repository on target"

CLONE_CMD="REPO_URL='${REPO_URL}' BRANCH='${BRANCH}'"
if [[ -n "$GITHUB_TOKEN" ]]; then
  # Inject token into HTTPS URL for private repo access
  CLONE_CMD="REPO_URL='root@10.0.0.101:/mnt/datapool/git/nclawzero.git' BRANCH='${BRANCH}'"
fi

run_remote "$(
  cat <<REPO_SETUP
set -euo pipefail
${CLONE_CMD}
WORK_DIR="${REMOTE_WORK_DIR}"

if [[ -d "\$WORK_DIR/.git" ]]; then
  echo "Updating existing clone..."
  cd "\$WORK_DIR"
  git fetch origin "\$BRANCH"
  git checkout "\$BRANCH"
  git reset --hard "origin/\$BRANCH"
else
  echo "Cloning..."
  mkdir -p "\$(dirname "\$WORK_DIR")"
  git clone --branch "\$BRANCH" "\$REPO_URL" "\$WORK_DIR"
fi
cd "\$WORK_DIR"
echo "Repo ready at \$WORK_DIR ($(git log --oneline -1))"
REPO_SETUP
)" && ok "Repository ready" || {
  fail "Repo setup failed"
  exit 1
}

# ── 3. Install npm deps + build ─────────────────────────────────────
step "Installing dependencies and building"

run_remote "$(
  cat <<DEPS
set -euo pipefail
cd ${REMOTE_WORK_DIR}
npm install --no-audit --no-fund
cd nemoclaw && npm install --no-audit --no-fund && npm run build && cd ..
echo "Dependencies installed and plugin built."
DEPS
)" && ok "Build complete" || {
  fail "Build failed"
  exit 1
}

# ── 4. Run unit tests ───────────────────────────────────────────────
step "Running unit tests"

run_remote "$(
  cat <<UNIT_TESTS
set -euo pipefail
cd ${REMOTE_WORK_DIR}
npx vitest run --reporter=verbose 2>&1 | tail -20
UNIT_TESTS
)" && ok "Unit tests passed" || fail "Some unit tests failed (continuing to E2E)"

# ── 5. Run E2E ──────────────────────────────────────────────────────
step "Running ZeroClaw E2E test"

E2E_ENV=""
if [[ -n "$NVIDIA_API_KEY" ]]; then
  E2E_ENV="export NVIDIA_API_KEY='${NVIDIA_API_KEY}'; "
fi
E2E_ENV+="export NEMOCLAW_NON_INTERACTIVE=1; export NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1; "

if $USE_STUB; then
  # Stub mode: build stub images first, then run the installer-based E2E
  run_remote "$(
    cat <<STUB_E2E
set -euo pipefail
cd ${REMOTE_WORK_DIR}
${E2E_ENV}

echo "Building stub images..."
bash scripts/build-stub-images.sh

echo "Running stub E2E..."
export NEMOCLAW_AGENT=zeroclaw
export NEMOCLAW_SANDBOX_NAME=e2e-zeroclaw-stub
export NEMOCLAW_RECREATE_SANDBOX=1
bash test/e2e/test-zeroclaw-e2e.sh 2>&1 | tee ${REMOTE_RESULTS}
STUB_E2E
  )" && ok "Stub E2E passed" || fail "Stub E2E failed"
else
  # Live mode: use the standalone E2E script (builds real images)
  EXTRA_ARGS=""
  if $KEEP_CONTAINER; then
    EXTRA_ARGS="--keep"
  fi

  run_remote "$(
    cat <<LIVE_E2E
set -euo pipefail
cd ${REMOTE_WORK_DIR}
${E2E_ENV}
bash scripts/zeroclaw-e2e.sh --repo ${REMOTE_WORK_DIR} ${EXTRA_ARGS} 2>&1
LIVE_E2E
  )" && ok "Live E2E passed" || fail "Live E2E failed"
fi

# ── 6. Copy results ─────────────────────────────────────────────────
step "Copying results"

mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOCAL_RESULTS="${RESULTS_DIR}/zeroclaw-e2e-${TARGET_MODE}-${TIMESTAMP}.txt"

copy_from_target "$REMOTE_RESULTS" "$LOCAL_RESULTS" 2>/dev/null && {
  ok "Results saved to: $LOCAL_RESULTS"
  echo ""
  echo "─── Results ───"
  cat "$LOCAL_RESULTS"
} || {
  fail "Could not copy results file"
}

# ── Summary ──────────────────────────────────────────────────────────
echo ""
step "Deploy complete"
info "Target:  ${TARGET_MODE} ${SSH_TARGET}${BREV_INSTANCE}"
info "Branch:  ${BRANCH}"
info "Mode:    $(if $USE_STUB; then echo 'stub'; else echo 'live'; fi)"
info "Results: ${LOCAL_RESULTS}"
