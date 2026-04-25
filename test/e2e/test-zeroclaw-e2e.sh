#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-FileCopyrightText: Copyright (c) 2026 Jason Perlow. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# ZeroClaw E2E: install → onboard --agent zeroclaw → verify sandbox → live inference
#
# Proves the COMPLETE ZeroClaw user journey including agent selection, health
# probe verification, and real inference through the sandbox. Uses the same
# install.sh --non-interactive path as the OpenClaw E2E but passes
# NEMOCLAW_AGENT=zeroclaw to select the ZeroClaw agent during onboarding.
#
# Prerequisites:
#   - Docker running
#   - NVIDIA_API_KEY set (real key, starts with nvapi-)
#   - Network access to integrate.api.nvidia.com
#
# Environment variables:
#   NEMOCLAW_NON_INTERACTIVE=1             — required (enables non-interactive install + onboard)
#   NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 — required for non-interactive install/onboard
#   NEMOCLAW_AGENT=zeroclaw               — auto-set if not already set
#   NEMOCLAW_SANDBOX_NAME                  — sandbox name (default: e2e-zeroclaw)
#   NEMOCLAW_RECREATE_SANDBOX=1            — recreate sandbox if it exists from a previous run
#   NVIDIA_API_KEY                         — required for NVIDIA Endpoints inference
#
# Usage:
#   NEMOCLAW_NON_INTERACTIVE=1 NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 NVIDIA_API_KEY=nvapi-... bash test/e2e/test-zeroclaw-e2e.sh

set -uo pipefail

PASS=0
FAIL=0
SKIP=0
TOTAL=0

pass() {
  ((PASS++))
  ((TOTAL++))
  printf '\033[32m  PASS: %s\033[0m\n' "$1"
}
fail() {
  ((FAIL++))
  ((TOTAL++))
  printf '\033[31m  FAIL: %s\033[0m\n' "$1"
}
skip() {
  ((SKIP++))
  ((TOTAL++))
  printf '\033[33m  SKIP: %s\033[0m\n' "$1"
}
section() {
  echo ""
  printf '\033[1;36m=== %s ===\033[0m\n' "$1"
}
info() { printf '\033[1;34m  [info]\033[0m %s\n' "$1"; }

# Parse chat completion response — handles both content and reasoning_content
parse_chat_content() {
  python3 -c "
import json, sys
try:
    r = json.load(sys.stdin)
    c = r['choices'][0]['message']
    content = c.get('content') or c.get('reasoning_content') or ''
    print(content.strip())
except Exception as e:
    print(f'PARSE_ERROR: {e}', file=sys.stderr)
    sys.exit(1)
"
}

# Determine repo root
if [ -d /workspace ] && [ -f /workspace/install.sh ]; then
  REPO="/workspace"
elif [ -f "$(cd "$(dirname "$0")/../.." && pwd)/install.sh" ]; then
  REPO="$(cd "$(dirname "$0")/../.." && pwd)"
else
  echo "ERROR: Cannot find repo root."
  exit 1
fi

SANDBOX_NAME="${NEMOCLAW_SANDBOX_NAME:-e2e-zeroclaw}"
export NEMOCLAW_AGENT="${NEMOCLAW_AGENT:-zeroclaw}"

# ZeroClaw health probe endpoint (from agents/zeroclaw/manifest.yaml)
ZEROCLAW_HEALTH_URL="http://localhost:42617/health"

# ══════════════════════════════════════════════════════════════════
# Phase 0: Pre-cleanup
# ══════════════════════════════════════════════════════════════════
section "Phase 0: Pre-cleanup"
info "Destroying any leftover sandbox/gateway from previous runs..."
if command -v nemoclaw >/dev/null 2>&1; then
  nemoclaw "$SANDBOX_NAME" destroy --yes 2>/dev/null || true
fi
if command -v openshell >/dev/null 2>&1; then
  openshell sandbox delete "$SANDBOX_NAME" 2>/dev/null || true
  openshell gateway destroy -g nemoclaw 2>/dev/null || true
fi
pass "Pre-cleanup complete"

# ══════════════════════════════════════════════════════════════════
# Phase 1: Prerequisites
# ══════════════════════════════════════════════════════════════════
section "Phase 1: Prerequisites"

if docker info >/dev/null 2>&1; then
  pass "Docker is running"
else
  fail "Docker is not running — cannot continue"
  exit 1
fi

if [ -n "${NVIDIA_API_KEY:-}" ] && [[ "${NVIDIA_API_KEY}" == nvapi-* ]]; then
  pass "NVIDIA_API_KEY is set (starts with nvapi-)"
else
  fail "NVIDIA_API_KEY not set or invalid — required for live inference"
  exit 1
fi

if curl -sf --max-time 10 https://integrate.api.nvidia.com/v1/models >/dev/null 2>&1; then
  pass "Network access to integrate.api.nvidia.com"
else
  fail "Cannot reach integrate.api.nvidia.com"
  exit 1
fi

if [ "${NEMOCLAW_NON_INTERACTIVE:-}" != "1" ]; then
  fail "NEMOCLAW_NON_INTERACTIVE=1 is required"
  exit 1
fi

if [ "${NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE:-}" != "1" ]; then
  fail "NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 is required for non-interactive install"
  exit 1
fi

if [ -d "$REPO/agents/zeroclaw" ] && [ -f "$REPO/agents/zeroclaw/manifest.yaml" ]; then
  pass "agents/zeroclaw/ directory and manifest.yaml exist"
else
  fail "agents/zeroclaw/ not found — is the nclawzero-rebase branch checked out?"
  exit 1
fi

info "NEMOCLAW_AGENT=${NEMOCLAW_AGENT}"

# ══════════════════════════════════════════════════════════════════
# Phase 2: Install nemoclaw (non-interactive mode, --agent zeroclaw)
# ══════════════════════════════════════════════════════════════════
section "Phase 2: Install nemoclaw (non-interactive mode, agent=zeroclaw)"

cd "$REPO" || {
  fail "Could not cd to repo root: $REPO"
  exit 1
}

info "Running install.sh --non-interactive with NEMOCLAW_AGENT=zeroclaw..."
info "This installs Node.js, openshell, NemoClaw, and runs onboard with ZeroClaw agent."
info "Expected duration: 8-12 minutes on first run (ZeroClaw base image build)."

INSTALL_LOG="/tmp/nemoclaw-e2e-zeroclaw-install.log"
bash install.sh --non-interactive >"$INSTALL_LOG" 2>&1 &
install_pid=$!
tail -f "$INSTALL_LOG" --pid=$install_pid 2>/dev/null &
tail_pid=$!
wait $install_pid
install_exit=$?
kill $tail_pid 2>/dev/null || true
wait $tail_pid 2>/dev/null || true

# Source shell profile to pick up nvm/PATH changes from install.sh
if [ -f "$HOME/.bashrc" ]; then
  # shellcheck source=/dev/null
  source "$HOME/.bashrc" 2>/dev/null || true
fi
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
if [ -s "$NVM_DIR/nvm.sh" ]; then
  # shellcheck source=/dev/null
  . "$NVM_DIR/nvm.sh"
fi
if [ -d "$HOME/.local/bin" ] && [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  export PATH="$HOME/.local/bin:$PATH"
fi

if [ $install_exit -eq 0 ]; then
  pass "install.sh completed (exit 0)"
else
  fail "install.sh failed (exit $install_exit)"
  exit 1
fi

if command -v nemoclaw >/dev/null 2>&1; then
  pass "nemoclaw installed at $(command -v nemoclaw)"
else
  fail "nemoclaw not found on PATH after install"
  exit 1
fi

if command -v openshell >/dev/null 2>&1; then
  pass "openshell installed ($(openshell --version 2>&1 || echo unknown))"
else
  fail "openshell not found on PATH after install"
  exit 1
fi

if nemoclaw --help >/dev/null 2>&1; then
  pass "nemoclaw --help exits 0"
else
  fail "nemoclaw --help failed"
fi

# ══════════════════════════════════════════════════════════════════
# Phase 3: Sandbox verification (ZeroClaw-specific)
# ══════════════════════════════════════════════════════════════════
section "Phase 3: Sandbox verification (ZeroClaw)"

# 3a: nemoclaw list
if list_output=$(nemoclaw list 2>&1); then
  if grep -Fq -- "$SANDBOX_NAME" <<<"$list_output"; then
    pass "nemoclaw list contains '${SANDBOX_NAME}'"
  else
    fail "nemoclaw list does not contain '${SANDBOX_NAME}'"
  fi
else
  fail "nemoclaw list failed: ${list_output:0:200}"
fi

# 3b: nemoclaw status
if status_output=$(nemoclaw "$SANDBOX_NAME" status 2>&1); then
  pass "nemoclaw ${SANDBOX_NAME} status exits 0"
else
  fail "nemoclaw ${SANDBOX_NAME} status failed: ${status_output:0:200}"
fi

# 3c: Session records agent=zeroclaw
session_file="$HOME/.nemoclaw/onboard-session.json"
if [ -f "$session_file" ]; then
  if grep -qE '"agent"\s*:\s*"zeroclaw"' "$session_file"; then
    pass "Onboard session records agent=zeroclaw"
  else
    fail "Onboard session does not contain agent=zeroclaw"
    info "Session contents: $(head -20 "$session_file" 2>/dev/null)"
  fi
else
  fail "Session file not found: $session_file"
fi

# 3d: Inference must be configured by onboard
if inf_check=$(openshell inference get 2>&1); then
  if grep -qi "nvidia-prod" <<<"$inf_check"; then
    pass "Inference configured via onboard"
  else
    fail "Inference not configured — onboard did not set up nvidia-prod provider"
  fi
else
  fail "openshell inference get failed: ${inf_check:0:200}"
fi

# 3e: Policy presets applied
if policy_output=$(openshell policy get --full "$SANDBOX_NAME" 2>&1); then
  if grep -qi "network_policies" <<<"$policy_output"; then
    pass "Policy applied to sandbox"
  else
    fail "No network policy found on sandbox"
  fi
else
  fail "openshell policy get failed: ${policy_output:0:200}"
fi

# ══════════════════════════════════════════════════════════════════
# Phase 4: ZeroClaw agent health verification
# ══════════════════════════════════════════════════════════════════
section "Phase 4: ZeroClaw agent health"

ssh_config="$(mktemp)"
TIMEOUT_CMD=""
command -v timeout >/dev/null 2>&1 && TIMEOUT_CMD="timeout 60"
command -v gtimeout >/dev/null 2>&1 && TIMEOUT_CMD="gtimeout 60"

# 4a: Health probe via SSH into sandbox
info "Checking ZeroClaw health probe at ${ZEROCLAW_HEALTH_URL} inside sandbox..."
zeroclaw_healthy=false

if openshell sandbox ssh-config "$SANDBOX_NAME" >"$ssh_config" 2>/dev/null; then
  # Retry health check — ZeroClaw may still be starting
  for attempt in $(seq 1 15); do
    health_response=$($TIMEOUT_CMD ssh -F "$ssh_config" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 \
      -o LogLevel=ERROR \
      "openshell-${SANDBOX_NAME}" \
      "curl -sf ${ZEROCLAW_HEALTH_URL}" \
      2>&1) || true

    if echo "$health_response" | grep -qi '"ok"\|"status"'; then
      zeroclaw_healthy=true
      break
    fi
    info "Health check attempt ${attempt}/15 — waiting 4s..."
    sleep 4
  done

  if $zeroclaw_healthy; then
    pass "ZeroClaw health probe returned ok"
    info "Response: ${health_response:0:200}"
  else
    fail "ZeroClaw health probe did not return ok after 15 attempts"
    info "Last response: ${health_response:0:200}"
  fi
else
  fail "Could not get SSH config for sandbox ${SANDBOX_NAME}"
fi

# 4b: Verify ZeroClaw binary exists in sandbox
if openshell sandbox ssh-config "$SANDBOX_NAME" >"$ssh_config" 2>/dev/null; then
  zeroclaw_version=$($TIMEOUT_CMD ssh -F "$ssh_config" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    -o LogLevel=ERROR \
    "openshell-${SANDBOX_NAME}" \
    "zeroclaw --version 2>&1 || echo MISSING" \
    2>&1) || true

  if echo "$zeroclaw_version" | grep -qi "MISSING\|not found\|No such file"; then
    fail "ZeroClaw binary not found in sandbox"
  else
    pass "ZeroClaw binary found in sandbox: ${zeroclaw_version:0:100}"
  fi
fi

# 4c: Verify ZeroClaw config exists
config_check=$($TIMEOUT_CMD ssh -F "$ssh_config" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout=10 \
  -o LogLevel=ERROR \
  "openshell-${SANDBOX_NAME}" \
  "test -f /sandbox/.zeroclaw/config.toml && echo EXISTS || echo MISSING" \
  2>&1) || true

if echo "$config_check" | grep -q "EXISTS"; then
  pass "ZeroClaw config.toml exists at /sandbox/.zeroclaw/config.toml"
else
  fail "ZeroClaw config.toml not found at /sandbox/.zeroclaw/config.toml"
fi

# 4d: Verify immutable config directory (Landlock read-only)
writable_check=$($TIMEOUT_CMD ssh -F "$ssh_config" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout=10 \
  -o LogLevel=ERROR \
  "openshell-${SANDBOX_NAME}" \
  "touch /sandbox/.zeroclaw/test-write 2>&1 && echo WRITABLE && rm -f /sandbox/.zeroclaw/test-write || echo READ_ONLY" \
  2>&1) || true

if echo "$writable_check" | grep -q "READ_ONLY"; then
  pass "ZeroClaw config directory is read-only (immutable)"
elif echo "$writable_check" | grep -q "WRITABLE"; then
  fail "ZeroClaw config directory is writable — should be immutable"
else
  skip "Could not determine config directory mutability: ${writable_check:0:100}"
fi

# 4e: Verify writable data directory exists
data_dir_check=$($TIMEOUT_CMD ssh -F "$ssh_config" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout=10 \
  -o LogLevel=ERROR \
  "openshell-${SANDBOX_NAME}" \
  "test -d /sandbox/.zeroclaw-data && echo EXISTS || echo MISSING" \
  2>&1) || true

if echo "$data_dir_check" | grep -q "EXISTS"; then
  pass "ZeroClaw writable data directory exists at /sandbox/.zeroclaw-data"
else
  fail "ZeroClaw writable data directory not found at /sandbox/.zeroclaw-data"
fi

# 4f: Verify NemoClaw WASM plugin is installed
plugin_check=$($TIMEOUT_CMD ssh -F "$ssh_config" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout=10 \
  -o LogLevel=ERROR \
  "openshell-${SANDBOX_NAME}" \
  "test -f /sandbox/.zeroclaw-data/plugins/nemoclaw/nemoclaw.wasm && echo EXISTS || echo MISSING" \
  2>&1) || true

if echo "$plugin_check" | grep -q "EXISTS"; then
  pass "NemoClaw WASM plugin exists at /sandbox/.zeroclaw-data/plugins/nemoclaw/nemoclaw.wasm"
else
  fail "NemoClaw WASM plugin not found"
fi

# 4g: Verify ZeroClaw status CLI inside sandbox
zeroclaw_status=$($TIMEOUT_CMD ssh -F "$ssh_config" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout=10 \
  -o LogLevel=ERROR \
  "openshell-${SANDBOX_NAME}" \
  "zeroclaw status 2>&1 || true" \
  2>&1) || true

if echo "$zeroclaw_status" | grep -qi "gateway\|running\|ok"; then
  pass "zeroclaw status reports gateway running"
else
  skip "zeroclaw status output unclear: ${zeroclaw_status:0:100}"
fi

rm -f "$ssh_config"

# ══════════════════════════════════════════════════════════════════
# Phase 5: Live inference — the real proof
# ══════════════════════════════════════════════════════════════════
section "Phase 5: Live inference"

# ── Test 5a: Direct NVIDIA Endpoints ──
info "[LIVE] Direct API test → integrate.api.nvidia.com..."
api_response=$(curl -s --max-time 30 \
  -X POST https://integrate.api.nvidia.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $NVIDIA_API_KEY" \
  -d '{
    "model": "nvidia/llama-3.1-nemotron-70b-instruct",
    "messages": [{"role": "user", "content": "Reply with exactly one word: PONG"}],
    "max_tokens": 100
  }' 2>/dev/null) || true

if [ -n "$api_response" ]; then
  api_content=$(echo "$api_response" | parse_chat_content 2>/dev/null) || true
  if grep -qi "PONG" <<<"$api_content"; then
    pass "[LIVE] Direct API: model responded with PONG"
  else
    fail "[LIVE] Direct API: expected PONG, got: ${api_content:0:200}"
  fi
else
  fail "[LIVE] Direct API: empty response from curl"
fi

# ── Test 5b: Inference through the ZeroClaw sandbox (THE definitive test) ──
info "[LIVE] Sandbox inference test → user → ZeroClaw sandbox → gateway → NVIDIA API..."
ssh_config="$(mktemp)"
sandbox_response=""

if openshell sandbox ssh-config "$SANDBOX_NAME" >"$ssh_config" 2>/dev/null; then
  TIMEOUT_CMD=""
  command -v timeout >/dev/null 2>&1 && TIMEOUT_CMD="timeout 90"
  command -v gtimeout >/dev/null 2>&1 && TIMEOUT_CMD="gtimeout 90"
  sandbox_response=$($TIMEOUT_CMD ssh -F "$ssh_config" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    -o LogLevel=ERROR \
    "openshell-${SANDBOX_NAME}" \
    "curl -s --max-time 60 https://inference.local/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -d '{\"model\":\"nvidia/llama-3.1-nemotron-70b-instruct\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly one word: PONG\"}],\"max_tokens\":100}'" \
    2>&1) || true
fi
rm -f "$ssh_config"

if [ -n "$sandbox_response" ]; then
  sandbox_content=$(echo "$sandbox_response" | parse_chat_content 2>/dev/null) || true
  if grep -qi "PONG" <<<"$sandbox_content"; then
    pass "[LIVE] Sandbox inference: model responded with PONG through ZeroClaw sandbox"
    info "Full path proven: user → ZeroClaw sandbox → openshell gateway → NVIDIA Endpoints → response"
  else
    fail "[LIVE] Sandbox inference: expected PONG, got: ${sandbox_content:0:200}"
  fi
else
  fail "[LIVE] Sandbox inference: no response from inference.local inside ZeroClaw sandbox"
fi

# ══════════════════════════════════════════════════════════════════
# Phase 6: NemoClaw CLI operations (ZeroClaw-specific)
# ══════════════════════════════════════════════════════════════════
section "Phase 6: NemoClaw CLI operations (ZeroClaw)"

info "Testing sandbox log retrieval..."
logs_output=$(nemoclaw "$SANDBOX_NAME" logs 2>&1) || true
if [ -n "$logs_output" ]; then
  pass "nemoclaw logs: produced output ($(echo "$logs_output" | wc -l | tr -d ' ') lines)"
else
  fail "nemoclaw logs: no output"
fi

# ══════════════════════════════════════════════════════════════════
# Phase 7: Agent regression check (openclaw + hermes + zeroclaw)
# ══════════════════════════════════════════════════════════════════
section "Phase 7: Agent regression check"

info "Verifying all agent manifests load correctly..."
agent_check=$(node -e "
  const { loadAgent, listAgents } = require('$REPO/bin/lib/agent-defs');
  const agents = listAgents();
  console.log('agents:', agents.join(', '));
  const oc = loadAgent('openclaw');
  console.log('openclaw_display:', oc.displayName);
  console.log('openclaw_supports_skills:', oc.supportsSkills);
  const zc = loadAgent('zeroclaw');
  console.log('zeroclaw_display:', zc.displayName);
  console.log('zeroclaw_port:', zc.forwardPort);
  console.log('zeroclaw_home_env_var:', zc.homeEnvVar);
  console.log('zeroclaw_supports_skills:', zc.supportsSkills);
  console.log('zeroclaw_install_method:', zc.install_method);
" 2>&1) || true

if echo "$agent_check" | grep -q "openclaw_display:.*OpenClaw"; then
  pass "OpenClaw agent manifest loads correctly"
else
  fail "OpenClaw agent manifest failed to load"
  info "Output: ${agent_check:0:300}"
fi

if echo "$agent_check" | grep -q "zeroclaw_display:.*ZeroClaw"; then
  pass "ZeroClaw agent manifest loads correctly"
else
  fail "ZeroClaw agent manifest failed to load"
  info "Output: ${agent_check:0:300}"
fi

if echo "$agent_check" | grep -q "zeroclaw_port:.*42617"; then
  pass "ZeroClaw forward port is 42617"
else
  fail "ZeroClaw forward port is not 42617"
  info "Output: ${agent_check:0:300}"
fi

if echo "$agent_check" | grep -qE "agents:.*zeroclaw"; then
  pass "ZeroClaw listed by listAgents()"
else
  fail "listAgents() did not include zeroclaw"
  info "Output: ${agent_check:0:300}"
fi

if echo "$agent_check" | grep -q "zeroclaw_home_env_var:.*ZEROCLAW_HOME"; then
  pass "ZeroClaw home_env_var is ZEROCLAW_HOME"
else
  fail "ZeroClaw home_env_var is not ZEROCLAW_HOME"
  info "Output: ${agent_check:0:300}"
fi

if echo "$agent_check" | grep -q "zeroclaw_supports_skills:.*false"; then
  pass "ZeroClaw supportsSkills is false (uses WASM plugins)"
else
  fail "ZeroClaw supportsSkills should be false"
  info "Output: ${agent_check:0:300}"
fi

if echo "$agent_check" | grep -q "zeroclaw_install_method:.*prebuilt"; then
  pass "ZeroClaw install_method is prebuilt"
else
  fail "ZeroClaw install_method is not prebuilt"
  info "Output: ${agent_check:0:300}"
fi

# ══════════════════════════════════════════════════════════════════
# Phase 8: Cleanup
# ══════════════════════════════════════════════════════════════════
section "Phase 8: Cleanup"

nemoclaw "$SANDBOX_NAME" destroy --yes 2>&1 | tail -3 || true
openshell gateway destroy -g nemoclaw 2>/dev/null || true

registry_file="${HOME}/.nemoclaw/sandboxes.json"
if [ -f "$registry_file" ] && grep -Fq "\"${SANDBOX_NAME}\"" "$registry_file"; then
  fail "Sandbox ${SANDBOX_NAME} still in registry after destroy"
else
  pass "Sandbox ${SANDBOX_NAME} removed"
fi

# ══════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════
echo ""
echo "========================================"
echo "  ZeroClaw Agent E2E Results:"
echo "    Passed:  $PASS"
echo "    Failed:  $FAIL"
echo "    Skipped: $SKIP"
echo "    Total:   $TOTAL"
echo "========================================"

if [ "$FAIL" -eq 0 ]; then
  printf '\n\033[1;32m  ZeroClaw E2E PASSED — agent selection + inference verified end-to-end.\033[0m\n'
  exit 0
else
  printf '\n\033[1;31m  %d test(s) failed.\033[0m\n' "$FAIL"
  exit 1
fi
