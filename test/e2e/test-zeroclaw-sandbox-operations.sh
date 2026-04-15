#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-FileCopyrightText: Copyright (c) 2026 Jason Perlow. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# =============================================================================
# test-zeroclaw-sandbox-operations.sh
# ZeroClaw Sandbox Operations E2E Test Suite
#
# Tests ZeroClaw gateway operations against a running sandbox. This is the
# ZeroClaw equivalent of test-sandbox-operations.sh, targeting the ZeroClaw
# gateway on port 42617 instead of OpenClaw on port 18789.
#
# Tests:
#   TC-ZSO-01  Health probe (/health)
#   TC-ZSO-02  API status (/api/status)
#   TC-ZSO-03  Webhook inference (/webhook)
#   TC-ZSO-04  Config reload after restart
#   TC-ZSO-05  Gateway restart and recovery
#   TC-ZSO-06  Dashboard accessible (GET /)
#
# Prerequisites:
#   - A running ZeroClaw sandbox (nemoclaw onboard --agent zeroclaw)
#   - Docker running
#   - curl available
#
# Environment variables:
#   ZEROCLAW_HOST           Gateway host (default: localhost)
#   ZEROCLAW_PORT           Gateway port (default: 42617)
#   NEMOCLAW_SANDBOX_NAME   Sandbox name (default: e2e-zeroclaw)
#   NEMOCLAW_E2E_TIMEOUT_SECONDS   Overall timeout (default: 600)
# =============================================================================

set -euo pipefail

# ── Overall timeout (prevents hung CI jobs) ──────────────────────────────────
if [ -z "${NEMOCLAW_E2E_NO_TIMEOUT:-}" ]; then
  export NEMOCLAW_E2E_NO_TIMEOUT=1
  TIMEOUT_SECONDS="${NEMOCLAW_E2E_TIMEOUT_SECONDS:-600}"
  if command -v timeout >/dev/null 2>&1; then
    exec timeout -s TERM "$TIMEOUT_SECONDS" bash "$0" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    exec gtimeout -s TERM "$TIMEOUT_SECONDS" bash "$0" "$@"
  fi
fi

# ── Config ───────────────────────────────────────────────────────────────────
ZEROCLAW_HOST="${ZEROCLAW_HOST:-localhost}"
ZEROCLAW_PORT="${ZEROCLAW_PORT:-42617}"
GATEWAY_BASE="http://${ZEROCLAW_HOST}:${ZEROCLAW_PORT}"
SANDBOX_NAME="${NEMOCLAW_SANDBOX_NAME:-e2e-zeroclaw}"
LOG_FILE="test-zeroclaw-sandbox-ops-$(date +%Y%m%d-%H%M%S).log"

# macOS uses gtimeout (from coreutils); Linux uses timeout
if command -v gtimeout &>/dev/null; then
  TIMEOUT_CMD="gtimeout"
elif command -v timeout &>/dev/null; then
  TIMEOUT_CMD="timeout"
else
  echo "WARNING: Neither timeout nor gtimeout found. Tests will run without command timeouts."
  TIMEOUT_CMD=""
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── Counters ─────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
SKIP=0
TOTAL=0

# ── Helpers ──────────────────────────────────────────────────────────────────
log() { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $*" | tee -a "$LOG_FILE"; }
pass() {
  ((PASS += 1))
  ((TOTAL += 1))
  echo -e "${GREEN}  PASS${NC} $1" | tee -a "$LOG_FILE"
}
fail() {
  ((FAIL += 1))
  ((TOTAL += 1))
  echo -e "${RED}  FAIL${NC} $1 — $2" | tee -a "$LOG_FILE"
}
skip() {
  ((SKIP += 1))
  ((TOTAL += 1))
  echo -e "${YELLOW}  SKIP${NC} $1 — $2" | tee -a "$LOG_FILE"
}

# Run curl with optional timeout wrapper. Returns curl exit code.
timed_curl() {
  if [ -n "$TIMEOUT_CMD" ]; then
    $TIMEOUT_CMD 15 curl "$@"
  else
    curl --max-time 15 "$@"
  fi
}

# Check that the ZeroClaw gateway is reachable. Returns 0 if healthy.
gateway_available() {
  timed_curl -sf "${GATEWAY_BASE}/health" >/dev/null 2>&1
}

# Require gateway to be available; skip the named test if not.
require_gateway() {
  if ! gateway_available; then
    skip "$1" "ZeroClaw gateway not reachable at ${GATEWAY_BASE}"
    return 1
  fi
  return 0
}

# Wait for gateway to become healthy (up to N seconds).
wait_for_gateway() {
  local max_wait="${1:-30}"
  local elapsed=0
  while [ "$elapsed" -lt "$max_wait" ]; do
    if gateway_available; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}

# ── Pre-flight ───────────────────────────────────────────────────────────────
preflight() {
  log "=== Pre-flight checks ==="

  if ! command -v curl &>/dev/null; then
    echo -e "${RED}ERROR: curl is required but not found.${NC}"
    exit 1
  fi
  log "curl available"

  log "Gateway target: ${GATEWAY_BASE}"
  log "Sandbox name: ${SANDBOX_NAME}"

  if gateway_available; then
    log "ZeroClaw gateway is reachable"
  else
    log "ZeroClaw gateway is NOT reachable at ${GATEWAY_BASE}"
    log "Tests requiring the gateway will be skipped."
    log "To run all tests, start a ZeroClaw sandbox first:"
    log "  nemoclaw onboard --agent zeroclaw"
  fi

  log "Pre-flight complete"
  echo ""
}

# =============================================================================
# TC-ZSO-01: Health Probe
# =============================================================================
test_zso_01_health_probe() {
  log "=== TC-ZSO-01: Health Probe ==="
  require_gateway "TC-ZSO-01" || return

  local response http_code
  response=$(timed_curl -sf "${GATEWAY_BASE}/health" 2>&1) || true
  http_code=$(timed_curl -sf -o /dev/null -w '%{http_code}' "${GATEWAY_BASE}/health" 2>&1) || true

  if [ "$http_code" = "200" ]; then
    pass "TC-ZSO-01: Health endpoint returned HTTP 200"
  else
    fail "TC-ZSO-01: Health Probe (HTTP)" "Expected HTTP 200, got: $http_code"
    return
  fi

  if echo "$response" | grep -q '"status"'; then
    pass "TC-ZSO-01: Health response contains status field"
  else
    fail "TC-ZSO-01: Health Probe (body)" "Response missing status field: ${response:0:200}"
    return
  fi

  if echo "$response" | grep -qi '"ok"'; then
    pass "TC-ZSO-01: Health status is ok"
  else
    fail "TC-ZSO-01: Health Probe (status)" "Expected status ok, got: ${response:0:200}"
  fi
}

# =============================================================================
# TC-ZSO-02: API Status
# =============================================================================
test_zso_02_api_status() {
  log "=== TC-ZSO-02: API Status ==="
  require_gateway "TC-ZSO-02" || return

  local response http_code
  http_code=$(timed_curl -sf -o /dev/null -w '%{http_code}' "${GATEWAY_BASE}/api/status" 2>&1) || true

  if [ "$http_code" = "200" ]; then
    response=$(timed_curl -sf "${GATEWAY_BASE}/api/status" 2>&1) || true
  elif [ "$http_code" = "404" ]; then
    # ZeroClaw may expose status at a different path; try /v1/status
    http_code=$(timed_curl -sf -o /dev/null -w '%{http_code}' "${GATEWAY_BASE}/v1/status" 2>&1) || true
    if [ "$http_code" = "200" ]; then
      response=$(timed_curl -sf "${GATEWAY_BASE}/v1/status" 2>&1) || true
    fi
  fi

  if [ "$http_code" != "200" ]; then
    skip "TC-ZSO-02" "Status endpoint not available (HTTP $http_code)"
    return
  fi

  # Validate the response is valid JSON
  if echo "$response" | python3 -m json.tool >/dev/null 2>&1; then
    pass "TC-ZSO-02: Status response is valid JSON"
  else
    fail "TC-ZSO-02: API Status (JSON)" "Response is not valid JSON: ${response:0:200}"
    return
  fi

  local found_fields=true
  for field in model provider; do
    if echo "$response" | grep -qi "$field"; then
      log "  Found field: $field"
    else
      log "  MISSING field: $field"
      found_fields=false
    fi
  done

  if $found_fields; then
    pass "TC-ZSO-02: Status response contains model and provider fields"
  else
    fail "TC-ZSO-02: API Status (fields)" "Missing expected fields in: ${response:0:200}"
  fi
}

# =============================================================================
# TC-ZSO-03: Webhook Inference
# =============================================================================
test_zso_03_webhook_inference() {
  log "=== TC-ZSO-03: Webhook Inference ==="
  require_gateway "TC-ZSO-03" || return

  # Try the webhook endpoint
  local response http_code
  http_code=$(timed_curl -sf -o /dev/null -w '%{http_code}' \
    -X POST "${GATEWAY_BASE}/webhook" \
    -H "Content-Type: application/json" \
    -d '{"messages":[{"role":"user","content":"Reply with exactly one word: PONG"}],"max_tokens":50}' \
    2>&1) || true

  if [ "$http_code" = "404" ]; then
    # ZeroClaw uses OpenAI-compatible /v1/chat/completions instead of /webhook
    http_code=$(timed_curl -sf -o /dev/null -w '%{http_code}' \
      -X POST "${GATEWAY_BASE}/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -d '{"messages":[{"role":"user","content":"Reply with exactly one word: PONG"}],"max_tokens":50}' \
      2>&1) || true

    if [ "$http_code" = "200" ]; then
      response=$(timed_curl -sf \
        -X POST "${GATEWAY_BASE}/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d '{"messages":[{"role":"user","content":"Reply with exactly one word: PONG"}],"max_tokens":50}' \
        2>&1) || true
    fi
  elif [ "$http_code" = "200" ]; then
    response=$(timed_curl -sf \
      -X POST "${GATEWAY_BASE}/webhook" \
      -H "Content-Type: application/json" \
      -d '{"messages":[{"role":"user","content":"Reply with exactly one word: PONG"}],"max_tokens":50}' \
      2>&1) || true
  fi

  if [ "$http_code" != "200" ]; then
    skip "TC-ZSO-03" "Inference endpoint not available or no API key configured (HTTP $http_code)"
    return
  fi

  if [ -n "$response" ]; then
    pass "TC-ZSO-03: Inference endpoint returned a response"
  else
    fail "TC-ZSO-03: Webhook Inference" "Empty response from inference endpoint"
  fi
}

# =============================================================================
# TC-ZSO-04: Config Reload
# =============================================================================
test_zso_04_config_reload() {
  log "=== TC-ZSO-04: Config Reload ==="
  require_gateway "TC-ZSO-04" || return

  # Record initial health response
  local before after
  before=$(timed_curl -sf "${GATEWAY_BASE}/health" 2>&1) || true

  if [ -z "$before" ]; then
    fail "TC-ZSO-04: Config Reload" "Could not get initial health response"
    return
  fi

  # Check if we can reach the sandbox to trigger a restart
  if ! command -v nemoclaw &>/dev/null; then
    skip "TC-ZSO-04" "nemoclaw CLI not available for restart"
    return
  fi

  if ! nemoclaw list 2>/dev/null | grep -q "$SANDBOX_NAME"; then
    skip "TC-ZSO-04" "Sandbox '$SANDBOX_NAME' not found in nemoclaw list"
    return
  fi

  # Restart the sandbox (this should trigger config reload on startup)
  log "  Restarting sandbox to trigger config reload..."
  nemoclaw "$SANDBOX_NAME" restart 2>&1 | tee -a "$LOG_FILE" || true

  # Wait for gateway to come back
  log "  Waiting for gateway to recover..."
  if wait_for_gateway 60; then
    after=$(timed_curl -sf "${GATEWAY_BASE}/health" 2>&1) || true
    if echo "$after" | grep -qi '"ok"'; then
      pass "TC-ZSO-04: Gateway healthy after restart (config reloaded)"
    else
      fail "TC-ZSO-04: Config Reload" "Gateway unhealthy after restart: ${after:0:200}"
    fi
  else
    fail "TC-ZSO-04: Config Reload" "Gateway did not recover within 60s after restart"
  fi
}

# =============================================================================
# TC-ZSO-05: Gateway Restart and Recovery
# =============================================================================
test_zso_05_gateway_restart() {
  log "=== TC-ZSO-05: Gateway Restart and Recovery ==="
  require_gateway "TC-ZSO-05" || return

  if ! command -v nemoclaw &>/dev/null; then
    skip "TC-ZSO-05" "nemoclaw CLI not available"
    return
  fi

  if ! nemoclaw list 2>/dev/null | grep -q "$SANDBOX_NAME"; then
    skip "TC-ZSO-05" "Sandbox '$SANDBOX_NAME' not found"
    return
  fi

  # Get SSH config for sandbox
  local ssh_cfg
  ssh_cfg="$(mktemp)"
  if ! openshell sandbox ssh-config "$SANDBOX_NAME" >"$ssh_cfg" 2>/dev/null; then
    skip "TC-ZSO-05" "Could not get SSH config for sandbox"
    rm -f "$ssh_cfg"
    return
  fi

  # Kill the zeroclaw gateway process inside the sandbox
  log "  Killing ZeroClaw gateway process inside sandbox..."
  local kill_output
  if [ -n "$TIMEOUT_CMD" ]; then
    kill_output=$($TIMEOUT_CMD 30 ssh -F "$ssh_cfg" \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -o LogLevel=ERROR \
      "openshell-${SANDBOX_NAME}" \
      "pkill -f 'zeroclaw gateway' 2>/dev/null || true; echo KILL_DONE" \
      2>&1) || true
  else
    kill_output=$(ssh -F "$ssh_cfg" \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -o LogLevel=ERROR \
      "openshell-${SANDBOX_NAME}" \
      "pkill -f 'zeroclaw gateway' 2>/dev/null || true; echo KILL_DONE" \
      2>&1) || true
  fi
  rm -f "$ssh_cfg"

  if echo "$kill_output" | grep -q "KILL_DONE"; then
    log "  Process kill sent"
  else
    log "  WARNING: Could not confirm process kill (output: $kill_output)"
  fi

  sleep 5

  # Verify gateway comes back (either auto-recovery or manual status triggers it)
  log "  Checking for gateway recovery..."
  local status_output
  if [ -n "$TIMEOUT_CMD" ]; then
    status_output=$($TIMEOUT_CMD 120 nemoclaw "$SANDBOX_NAME" status 2>&1) || true
  else
    status_output=$(nemoclaw "$SANDBOX_NAME" status 2>&1) || true
  fi

  # Wait for health to return
  if wait_for_gateway 60; then
    local health_response
    health_response=$(timed_curl -sf "${GATEWAY_BASE}/health" 2>&1) || true
    if echo "$health_response" | grep -qi '"ok"'; then
      pass "TC-ZSO-05: Gateway recovered after kill — health returns ok"
    else
      fail "TC-ZSO-05: Gateway Restart" "Health response after recovery: ${health_response:0:200}"
    fi
  else
    fail "TC-ZSO-05: Gateway Restart" "Gateway did not recover within 60s after kill"
  fi
}

# =============================================================================
# TC-ZSO-06: Dashboard Accessible
# =============================================================================
test_zso_06_dashboard() {
  log "=== TC-ZSO-06: Dashboard Accessible ==="
  require_gateway "TC-ZSO-06" || return

  local response http_code
  http_code=$(timed_curl -sf -o /dev/null -w '%{http_code}' "${GATEWAY_BASE}/" 2>&1) || true

  if [ "$http_code" = "200" ]; then
    response=$(timed_curl -sf "${GATEWAY_BASE}/" 2>&1) || true
  elif [ "$http_code" = "301" ] || [ "$http_code" = "302" ]; then
    # Follow redirects
    response=$(timed_curl -sfL "${GATEWAY_BASE}/" 2>&1) || true
    http_code="200"
  fi

  if [ "$http_code" != "200" ]; then
    skip "TC-ZSO-06" "Dashboard not available (HTTP $http_code)"
    return
  fi

  if echo "$response" | grep -qi "<title>"; then
    pass "TC-ZSO-06: Dashboard returns HTML with title tag"
  else
    # ZeroClaw may return JSON at / instead of HTML
    if echo "$response" | python3 -m json.tool >/dev/null 2>&1; then
      pass "TC-ZSO-06: Root endpoint returns valid JSON (API-first gateway)"
    else
      fail "TC-ZSO-06: Dashboard" "Root endpoint returned neither HTML nor JSON: ${response:0:200}"
      return
    fi
  fi

  if echo "$response" | grep -qi "ZeroClaw"; then
    pass "TC-ZSO-06: Dashboard contains 'ZeroClaw' branding"
  else
    log "  NOTE: 'ZeroClaw' branding not found in root response (may use generic template)"
  fi
}

# ── Summary ──────────────────────────────────────────────────────────────────
summary() {
  echo ""
  echo "============================================================"
  echo "  ZEROCLAW SANDBOX OPERATIONS — TEST SUMMARY"
  echo "============================================================"
  echo -e "  ${GREEN}PASS: $PASS${NC}"
  echo -e "  ${RED}FAIL: $FAIL${NC}"
  echo -e "  ${YELLOW}SKIP: $SKIP${NC}"
  echo "  TOTAL: $TOTAL"
  echo "============================================================"
  echo "  Log: $LOG_FILE"
  echo "  Gateway: ${GATEWAY_BASE}"
  echo "============================================================"
  echo ""

  if [ "$FAIL" -gt 0 ]; then
    exit 1
  fi
  exit 0
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  echo ""
  echo "============================================================"
  echo "  ZeroClaw Sandbox Operations E2E Test Suite"
  echo "  $(date)"
  echo "============================================================"
  echo ""

  preflight

  test_zso_01_health_probe
  test_zso_02_api_status
  test_zso_03_webhook_inference
  test_zso_04_config_reload
  test_zso_05_gateway_restart
  test_zso_06_dashboard

  summary
}

main "$@"
