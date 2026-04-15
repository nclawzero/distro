#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-FileCopyrightText: Copyright (c) 2026 Jason Perlow. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# ZeroClaw Provider & Integration Test Harness
#
# Validates that a ZeroClaw installation has working providers, local
# inference, model routing, and (optionally) containerized deployment
# via the NemoClaw blueprint.
#
# Usage:
#   scripts/zeroclaw-provider-harness.sh [OPTIONS]
#
# Options:
#   --gateway-url URL   Gateway base URL (default: http://localhost:42617)
#   --ollama-url  URL   Ollama API URL  (default: http://localhost:11434)
#   --container-image TAG  Also test containerized ZeroClaw (skipped if omitted)
#   --results PATH      Results file (default: /tmp/zeroclaw-harness-results.txt)
#   --skip-inference     Skip live inference tests (health + config only)
#
# Prerequisites:
#   - ZeroClaw gateway running (or script starts it)
#   - API keys in environment (source ~/.zeroclaw/.env first)
#   - Ollama running locally for local-model tests
#   - Docker for container tests

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────
GATEWAY_URL="${GATEWAY_URL:-http://localhost:42617}"
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
CONTAINER_IMAGE=""
RESULTS_FILE="/tmp/zeroclaw-harness-results.txt"
SKIP_INFERENCE=false
CONTAINER_NAME="zeroclaw-harness-test"
INFERENCE_TIMEOUT=45

# ── Argument parsing ──────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --gateway-url)
      GATEWAY_URL="$2"
      shift 2
      ;;
    --ollama-url)
      OLLAMA_URL="$2"
      shift 2
      ;;
    --container-image)
      CONTAINER_IMAGE="$2"
      shift 2
      ;;
    --results)
      RESULTS_FILE="$2"
      shift 2
      ;;
    --skip-inference)
      SKIP_INFERENCE=true
      shift
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
PASS=0
FAIL=0
SKIP=0
WARN=0
step() { printf '\n\033[1;36m━━ %s\033[0m\n' "$*" | tee -a "$RESULTS_FILE"; }
ok() {
  PASS=$((PASS + 1))
  printf '\033[1;32m  ✓ %s\033[0m\n' "$*" | tee -a "$RESULTS_FILE"
}
fail() {
  FAIL=$((FAIL + 1))
  printf '\033[1;31m  ✗ %s\033[0m\n' "$*" | tee -a "$RESULTS_FILE"
}
warn() {
  WARN=$((WARN + 1))
  printf '\033[1;33m  ⚠ %s\033[0m\n' "$*" | tee -a "$RESULTS_FILE"
}
skip() {
  SKIP=$((SKIP + 1))
  printf '\033[0;90m  ○ %s (skipped)\033[0m\n' "$*" | tee -a "$RESULTS_FILE"
}
info() { printf '  %s\n' "$*" | tee -a "$RESULTS_FILE"; }

mkdir -p "$(dirname "$RESULTS_FILE")"
printf 'ZeroClaw Provider Test Harness — %s\n%s\n\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(uname -a)" >"$RESULTS_FILE"

# shellcheck disable=SC2329
cleanup() {
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

# ── Helper: test a single provider via /v1/chat/completions ───────
# Uses the OpenAI-compatible endpoint directly with the provider's
# base_url, bypassing the gateway's default routing. This lets us
# validate each provider independently.
test_provider_direct() {
  local name="$1" base_url="$2" api_key="$3" model="$4"

  if [ -z "$api_key" ]; then
    warn "$name — API key not set, cannot test"
    return
  fi

  local resp
  resp=$(curl -sf --max-time "$INFERENCE_TIMEOUT" \
    -X POST "${base_url}/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${api_key}" \
    -d "{
      \"model\": \"${model}\",
      \"messages\": [{\"role\":\"user\",\"content\":\"Reply with exactly one word: PASS\"}],
      \"max_tokens\": 10,
      \"temperature\": 0
    }" 2>&1) || true

  local verdict
  verdict=$(echo "$resp" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    if 'error' in d:
        print(f'FAIL:{d[\"error\"].get(\"message\",str(d[\"error\"]))[:120]}')
    elif 'choices' in d:
        content=d['choices'][0]['message']['content'].strip()
        model_used=d.get('model','?')
        if content:
            print(f'OK:model={model_used}, response=\"{content[:60]}\"')
        else:
            print(f'WARN:model={model_used}, empty response (API returned 200 but no content)')
    else:
        print(f'FAIL:unexpected format: {str(d)[:100]}')
except Exception as e:
    print(f'FAIL:parse error: {e}')
" 2>/dev/null || echo "FAIL:no response from $base_url")

  case "$verdict" in
    OK:*) ok "$name — inference OK (${verdict#OK:})" ;;
    WARN:*) warn "$name — ${verdict#WARN:}" ;;
    FAIL:*) fail "$name — ${verdict#FAIL:}" ;;
  esac
}

# ── Helper: test Ollama inference ─────────────────────────────────
test_ollama_model() {
  local model="$1" label="$2"

  local resp
  resp=$(curl -sf --max-time 90 \
    -X POST "${OLLAMA_URL}/api/chat" \
    -d "{
      \"model\": \"${model}\",
      \"messages\": [{\"role\":\"user\",\"content\":\"Reply with exactly one word: PASS\"}],
      \"stream\": false
    }" 2>&1) || true

  if echo "$resp" | python3 -c "
import json,sys
d=json.load(sys.stdin)
content=d['message']['content'].strip()
sys.exit(0 if content else 1)
" 2>/dev/null; then
    local content
    content=$(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin)['message']['content'].strip()[:80])" 2>/dev/null)
    ok "$label — inference OK (response=\"$content\")"
  else
    fail "$label — inference failed"
  fi
}

# ══════════════════════════════════════════════════════════════════
# PHASE 1: Gateway Health
# ══════════════════════════════════════════════════════════════════
step "Phase 1: Gateway Health"

HEALTH_RESP=$(curl -sf --max-time 5 "${GATEWAY_URL}/health" 2>/dev/null || echo "UNREACHABLE")

if echo "$HEALTH_RESP" | python3 -c "import json,sys; sys.exit(0 if json.load(sys.stdin).get('status')=='ok' else 1)" 2>/dev/null; then
  ok "Gateway health probe — status=ok"
else
  fail "Gateway health probe — $HEALTH_RESP"
  if [ "$HEALTH_RESP" = "UNREACHABLE" ]; then
    info "Gateway not running at $GATEWAY_URL. Start it first:"
    info "  source ~/.zeroclaw/.env && zeroclaw gateway start"
    # Don't exit — continue with tests that don't need the gateway
  fi
fi

# Check pairing status
if echo "$HEALTH_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get('require_pairing')==False else 1)" 2>/dev/null; then
  ok "Gateway pairing — disabled (open access)"
else
  warn "Gateway pairing — enabled (webhook tests may fail without pairing)"
fi

# Check uptime
UPTIME=$(echo "$HEALTH_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('runtime',{}).get('uptime_seconds','?'))" 2>/dev/null || echo "?")
info "Gateway uptime: ${UPTIME}s"

# ══════════════════════════════════════════════════════════════════
# PHASE 2: Local Ollama
# ══════════════════════════════════════════════════════════════════
step "Phase 2: Local Ollama"

OLLAMA_TAGS=$(curl -sf --max-time 5 "${OLLAMA_URL}/api/tags" 2>/dev/null || echo "UNREACHABLE")

if [ "$OLLAMA_TAGS" = "UNREACHABLE" ]; then
  fail "Ollama not reachable at $OLLAMA_URL"
else
  MODEL_COUNT=$(echo "$OLLAMA_TAGS" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('models',[])))" 2>/dev/null || echo 0)
  ok "Ollama reachable — $MODEL_COUNT model(s) available"

  # List models
  echo "$OLLAMA_TAGS" | python3 -c "
import json,sys
for m in json.load(sys.stdin).get('models',[]):
    print(f\"    {m['name']:35s} {m['size']/1e9:.1f}GB\")
" 2>/dev/null | tee -a "$RESULTS_FILE"

  if [ "$SKIP_INFERENCE" = false ]; then
    # Test each local model
    for model in gemma4-e4b-opt gemma4-consult gemma4:e4b; do
      if echo "$OLLAMA_TAGS" | grep -q "\"$model"; then
        test_ollama_model "$model" "Ollama/$model"
      else
        skip "Ollama/$model — model not installed"
      fi
    done
  else
    skip "Ollama inference tests (--skip-inference)"
  fi
fi

# GPU info
if command -v nvidia-smi &>/dev/null; then
  GPU_INFO=$(nvidia-smi --query-gpu=name,memory.total,memory.used --format=csv,noheader 2>/dev/null || echo "unavailable")
  info "GPU: $GPU_INFO"
else
  info "GPU: nvidia-smi not available"
fi

# ══════════════════════════════════════════════════════════════════
# PHASE 3: Cloud Provider Inference (direct API calls)
# ══════════════════════════════════════════════════════════════════
step "Phase 3: Cloud Provider Inference"

if [ "$SKIP_INFERENCE" = true ]; then
  skip "All cloud inference tests (--skip-inference)"
else
  # Together AI (use Llama for reliable short responses; MiniMax needs higher max_tokens)
  test_provider_direct "Together AI" \
    "https://api.together.xyz/v1" \
    "${TOGETHER_API_KEY:-}" \
    "meta-llama/Llama-3.3-70B-Instruct-Turbo"

  # Groq
  test_provider_direct "Groq" \
    "https://api.groq.com/openai/v1" \
    "${GROQ_API_KEY:-}" \
    "llama-3.3-70b-versatile"

  # xAI (Grok)
  test_provider_direct "xAI (Grok)" \
    "https://api.x.ai/v1" \
    "${XAI_API_KEY:-}" \
    "grok-4-1-fast-non-reasoning"

  # OpenAI
  test_provider_direct "OpenAI" \
    "https://api.openai.com/v1" \
    "${OPENAI_API_KEY:-}" \
    "gpt-4.1-nano"

  # NVIDIA NIM
  test_provider_direct "NVIDIA NIM" \
    "https://integrate.api.nvidia.com/v1" \
    "${NVIDIA_API_KEY:-}" \
    "meta/llama-4-maverick-17b-128e-instruct"

  # Perplexity
  test_provider_direct "Perplexity" \
    "https://api.perplexity.ai" \
    "${PERPLEXITY_API_KEY:-}" \
    "sonar-pro"

  # Google Gemini (uses different API format — OpenAI-compatible endpoint)
  test_provider_direct "Gemini" \
    "https://generativelanguage.googleapis.com/v1beta/openai" \
    "${GEMINI_API_KEY:-${GOOGLE_API_KEY:-}}" \
    "gemini-2.0-flash"
fi

# ══════════════════════════════════════════════════════════════════
# PHASE 4: Gateway Webhook (default provider routing)
# ══════════════════════════════════════════════════════════════════
step "Phase 4: Gateway Webhook Routing"

if [ "$HEALTH_RESP" = "UNREACHABLE" ] || [ "$SKIP_INFERENCE" = true ]; then
  skip "Gateway webhook tests (gateway unreachable or --skip-inference)"
else
  WEBHOOK_RESP=$(curl -sf --max-time "$INFERENCE_TIMEOUT" \
    -X POST "${GATEWAY_URL}/webhook" \
    -H "Content-Type: application/json" \
    -d '{"message":"Reply with exactly one word: PASS"}' 2>&1) || true

  if echo "$WEBHOOK_RESP" | python3 -c "
import json,sys
d=json.load(sys.stdin)
sys.exit(0 if d.get('response') or d.get('message') else 1)
" 2>/dev/null; then
    local_resp=$(echo "$WEBHOOK_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"model={d.get('model','?')} response={str(d.get('response',d.get('message','')))[:60]}\")" 2>/dev/null)
    ok "Gateway webhook (default) — $local_resp"
  else
    fail "Gateway webhook (default) — no response"
    info "Raw: $(echo "$WEBHOOK_RESP" | head -c 200)"
  fi
fi

# ══════════════════════════════════════════════════════════════════
# PHASE 5: ZeroClaw Config Validation
# ══════════════════════════════════════════════════════════════════
step "Phase 5: Config Validation"

CONFIG_FILE="${HOME}/.zeroclaw/config.toml"
ENV_FILE="${HOME}/.zeroclaw/.env"

if [ -f "$CONFIG_FILE" ]; then
  ok "Config file exists: $CONFIG_FILE"

  # Check key settings
  PROVIDER=$(grep "^default_provider" "$CONFIG_FILE" | head -1 | cut -d'"' -f2)
  MODEL=$(grep "^default_model" "$CONFIG_FILE" | head -1 | cut -d'"' -f2)
  info "Default provider: $PROVIDER"
  info "Default model: $MODEL"

  # Count model routes
  ROUTE_COUNT=$(grep -c '^\[\[model_routes\]\]' "$CONFIG_FILE" || echo 0)
  if [ "$ROUTE_COUNT" -gt 0 ]; then
    ok "Model routes — $ROUTE_COUNT route(s) configured"
  else
    warn "No model routes configured"
  fi

  # Check model_providers
  PROVIDER_COUNT=$(grep -c '^\[model_providers\.' "$CONFIG_FILE" || echo 0)
  if [ "$PROVIDER_COUNT" -gt 0 ]; then
    ok "Model providers — $PROVIDER_COUNT custom provider(s)"
    grep '^\[model_providers\.' "$CONFIG_FILE" | sed 's/\[model_providers\.\(.*\)\]/    \1/' | tee -a "$RESULTS_FILE"
  fi

  # Gateway config
  if grep -q 'require_pairing = false' "$CONFIG_FILE"; then
    ok "Gateway pairing disabled in config"
  else
    warn "Gateway pairing not explicitly disabled in config"
  fi
else
  fail "Config file not found: $CONFIG_FILE"
fi

if [ -f "$ENV_FILE" ]; then
  KEY_COUNT=$(grep -c '_KEY=' "$ENV_FILE" || echo 0)
  ok "Environment file exists — $KEY_COUNT API key(s)"
  # List key names without values
  grep '_KEY=' "$ENV_FILE" | cut -d= -f1 | sed 's/^/    /' | tee -a "$RESULTS_FILE"
else
  warn "No .env file at $ENV_FILE — keys must be in environment"
fi

# ══════════════════════════════════════════════════════════════════
# PHASE 6: Containerized ZeroClaw (NemoClaw blueprint)
# ══════════════════════════════════════════════════════════════════
step "Phase 6: Containerized ZeroClaw"

if [ -z "$CONTAINER_IMAGE" ]; then
  skip "Container tests (pass --container-image TAG to enable)"
else
  info "Testing image: $CONTAINER_IMAGE"
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

  # Start container on a different port to avoid conflict
  # shellcheck disable=SC2034
  CONTAINER_PORT=42618
  docker run -d \
    --name "$CONTAINER_NAME" \
    --network host \
    --entrypoint /usr/local/bin/nemoclaw-start \
    -e TOGETHER_API_KEY="${TOGETHER_API_KEY:-}" \
    -e NVIDIA_API_KEY="${NVIDIA_API_KEY:-}" \
    -e GROQ_API_KEY="${GROQ_API_KEY:-}" \
    -e XAI_API_KEY="${XAI_API_KEY:-}" \
    -e OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
    -e PERPLEXITY_API_KEY="${PERPLEXITY_API_KEY:-}" \
    -e GOOGLE_API_KEY="${GOOGLE_API_KEY:-}" \
    -e GEMINI_API_KEY="${GEMINI_API_KEY:-}" \
    "$CONTAINER_IMAGE" >/dev/null 2>&1

  # Wait for health
  CONTAINER_HEALTH=false
  for i in $(seq 1 12); do
    sleep 5
    C_RESP=$(curl -sf http://localhost:42617/health 2>/dev/null || true)
    if echo "$C_RESP" | grep -q '"ok"'; then
      CONTAINER_HEALTH=true
      break
    fi
    info "  Waiting for container health... ($((i * 5))s)"
  done

  if [ "$CONTAINER_HEALTH" = true ]; then
    ok "Container health probe — status=ok"

    # Verify no stub marker
    if echo "$C_RESP" | grep -q '"stub"'; then
      fail "Container is running STUB binary (not real zeroclaw)"
    else
      ok "Container running real zeroclaw binary"
    fi
  else
    fail "Container health probe timed out (60s)"
    info "Container logs:"
    docker logs "$CONTAINER_NAME" 2>&1 | tail -10 | tee -a "$RESULTS_FILE"
  fi

  # Config integrity check
  C_LOGS=$(docker logs "$CONTAINER_NAME" 2>&1)
  if echo "$C_LOGS" | grep -q "Deployed verified config"; then
    ok "Container config integrity — sha256 verified"
  else
    fail "Container config integrity check not confirmed"
  fi

  # Security hardening
  if echo "$C_LOGS" | grep -q "Immutable hardening"; then
    ok "Container security hardening — applied"
  else
    warn "Container security hardening log not found"
  fi

  # Check privilege separation (gateway user)
  if echo "$C_LOGS" | grep -q "gateway.*user"; then
    ok "Container privilege separation — gateway user active"
  else
    warn "Container privilege separation not confirmed in logs"
  fi

  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
fi

# ══════════════════════════════════════════════════════════════════
# PHASE 7: Provider Failover
# ══════════════════════════════════════════════════════════════════
step "Phase 7: Reliability Config"

if [ -f "$CONFIG_FILE" ]; then
  FALLBACKS=$(grep -A5 '\[reliability\]' "$CONFIG_FILE" | grep 'fallback_providers' || echo "none")
  RETRIES=$(grep -A5 '\[reliability\]' "$CONFIG_FILE" | grep 'provider_retries' | head -1 || echo "none")
  if [ "$FALLBACKS" != "none" ]; then
    ok "Failover configured: $FALLBACKS"
  else
    warn "No fallback_providers configured in [reliability]"
  fi
  if [ "$RETRIES" != "none" ]; then
    info "Retry policy: $RETRIES"
  fi
else
  skip "Config not available for reliability check"
fi

# ══════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════
step "Summary"
echo "" | tee -a "$RESULTS_FILE"
printf '  Passed:  %d\n' "$PASS" | tee -a "$RESULTS_FILE"
printf '  Failed:  %d\n' "$FAIL" | tee -a "$RESULTS_FILE"
printf '  Warned:  %d\n' "$WARN" | tee -a "$RESULTS_FILE"
printf '  Skipped: %d\n' "$SKIP" | tee -a "$RESULTS_FILE"
echo "" | tee -a "$RESULTS_FILE"

if [ "$FAIL" -eq 0 ]; then
  printf '\033[1;32m  PASS — all %d checks passed (%s)\033[0m\n' \
    "$PASS" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$RESULTS_FILE"
  echo ""
  info "Results: $RESULTS_FILE"
  exit 0
else
  printf '\033[1;31m  FAIL — %d of %d check(s) failed\033[0m\n' \
    "$FAIL" "$((PASS + FAIL))" | tee -a "$RESULTS_FILE"
  echo ""
  info "Results: $RESULTS_FILE"
  exit 1
fi
