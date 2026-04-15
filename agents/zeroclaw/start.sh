#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-FileCopyrightText: Copyright (c) 2026 Jason Perlow. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# NemoClaw sandbox entrypoint for ZeroClaw.
#
# Mirrors agents/hermes/start.sh but launches `zeroclaw gateway start`
# instead of `hermes gateway run`. Key differences vs. Hermes:
#   - No device-pairing auto-pair watcher (ZeroClaw pairing is disabled in config)
#   - Config is TOML (config.toml) not YAML/JSON
#   - ZeroClaw binds to [::]:{port} directly — no socat forwarder needed
#   - ZeroClaw is a Rust binary — no URL-decode proxy needed (reqwest
#     handles HTTPS_PROXY correctly without path encoding issues)
#   - ZEROCLAW_HOME points to the writable data dir (not immutable config dir)
#
# SECURITY: The gateway runs as a separate user so the sandboxed agent cannot
# kill it or restart it with a tampered config. Config hash is verified at
# startup to detect tampering.

set -euo pipefail

# Harden: limit process count to prevent fork bombs
if ! ulimit -Su 512 2>/dev/null; then
  echo "[SECURITY] Could not set soft nproc limit (container runtime may restrict ulimit)" >&2
fi
if ! ulimit -Hu 512 2>/dev/null; then
  echo "[SECURITY] Could not set hard nproc limit (container runtime may restrict ulimit)" >&2
fi

# SECURITY: Lock down PATH
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ── Drop unnecessary Linux capabilities ──────────────────────────
if [ "${NEMOCLAW_CAPS_DROPPED:-}" != "1" ] && command -v capsh >/dev/null 2>&1; then
  if capsh --has-p=cap_setpcap 2>/dev/null; then
    export NEMOCLAW_CAPS_DROPPED=1
    exec capsh \
      --drop=cap_net_raw,cap_dac_override,cap_sys_chroot,cap_fsetid,cap_setfcap,cap_mknod,cap_audit_write,cap_net_bind_service \
      -- -c 'exec /usr/local/bin/nemoclaw-start "$@"' -- "$@"
  else
    echo "[SECURITY] CAP_SETPCAP not available — runtime already restricts capabilities" >&2
  fi
elif [ "${NEMOCLAW_CAPS_DROPPED:-}" != "1" ]; then
  echo "[SECURITY WARNING] capsh not available — running with default capabilities" >&2
fi

# Normalize the self-wrapper bootstrap (same pattern as Hermes entrypoint).
if [ "${1:-}" = "env" ]; then
  _raw_args=("$@")
  _self_wrapper_index=""
  for ((i = 1; i < ${#_raw_args[@]}; i += 1)); do
    case "${_raw_args[$i]}" in
      *=*) ;;
      nemoclaw-start | /usr/local/bin/nemoclaw-start)
        _self_wrapper_index="$i"
        break
        ;;
      *)
        break
        ;;
    esac
  done
  if [ -n "$_self_wrapper_index" ]; then
    for ((i = 1; i < _self_wrapper_index; i += 1)); do
      export "${_raw_args[$i]}"
    done
    set -- "${_raw_args[@]:$((_self_wrapper_index + 1))}"
  fi
fi

case "${1:-}" in
  nemoclaw-start | /usr/local/bin/nemoclaw-start) shift ;;
esac
NEMOCLAW_CMD=("$@")
GATEWAY_PORT=42617
ZEROCLAW="$(command -v zeroclaw)" # Resolve once, use absolute path everywhere

ZEROCLAW_IMMUTABLE="/sandbox/.zeroclaw"
ZEROCLAW_WRITABLE="/sandbox/.zeroclaw-data"

# ── Config integrity check ──────────────────────────────────────
verify_config_integrity() {
  local hash_file="${ZEROCLAW_IMMUTABLE}/.config-hash"
  if [ ! -f "$hash_file" ]; then
    echo "[SECURITY] Config hash file missing — refusing to start without integrity verification" >&2
    return 1
  fi
  if ! (cd "${ZEROCLAW_IMMUTABLE}" && sha256sum -c "$hash_file" --status 2>/dev/null); then
    echo "[SECURITY] ZeroClaw config integrity check FAILED — config may have been tampered with" >&2
    return 1
  fi
}

# Copy verified immutable config into the writable ZEROCLAW_HOME so the
# gateway process can read it alongside its own state files.
deploy_config_to_writable() {
  if [ "$(id -u)" -eq 0 ]; then
    gosu sandbox cp "${ZEROCLAW_IMMUTABLE}/config.toml" "${ZEROCLAW_WRITABLE}/config.toml"
  else
    cp "${ZEROCLAW_IMMUTABLE}/config.toml" "${ZEROCLAW_WRITABLE}/config.toml"
  fi
  chmod 600 "${ZEROCLAW_WRITABLE}/config.toml" 2>/dev/null || true
  echo "[config] Deployed verified config to ${ZEROCLAW_WRITABLE}" >&2
}

install_configure_guard() {
  local marker_begin="# nemoclaw-configure-guard begin"
  local marker_end="# nemoclaw-configure-guard end"
  local snippet
  read -r -d '' snippet <<'GUARD' || true
# nemoclaw-configure-guard begin
zeroclaw() {
  case "$1" in
    onboard|service)
      echo "Error: 'zeroclaw $1' cannot modify config inside the sandbox." >&2
      echo "The sandbox config is read-only (Landlock enforced) for security." >&2
      echo "" >&2
      echo "To change your configuration, exit the sandbox and run:" >&2
      echo "  nemoclaw onboard --resume" >&2
      return 1
      ;;
  esac
  command zeroclaw "$@"
}
# nemoclaw-configure-guard end
GUARD

  for rc_file in "${_SANDBOX_HOME}/.bashrc" "${_SANDBOX_HOME}/.profile"; do
    if [ -f "$rc_file" ] && grep -qF "$marker_begin" "$rc_file" 2>/dev/null; then
      local tmp
      tmp="$(mktemp)"
      awk -v b="$marker_begin" -v e="$marker_end" \
        '$0==b{s=1;next} $0==e{s=0;next} !s' "$rc_file" >"$tmp"
      printf '%s\n' "$snippet" >>"$tmp"
      cat "$tmp" >"$rc_file"
      rm -f "$tmp"
    elif [ -w "$rc_file" ] || [ -w "$(dirname "$rc_file")" ]; then
      printf '\n%s\n' "$snippet" >>"$rc_file"
    fi
  done
}

validate_zeroclaw_symlinks() {
  local entry name target expected
  for entry in /sandbox/.zeroclaw/*; do
    [ -L "$entry" ] || continue
    name="$(basename "$entry")"
    target="$(readlink -f "$entry" 2>/dev/null || true)"
    expected="/sandbox/.zeroclaw-data/$name"
    if [ "$target" != "$expected" ]; then
      echo "[SECURITY] Symlink $entry points to unexpected target: $target (expected $expected)" >&2
      return 1
    fi
  done
}

harden_zeroclaw_symlinks() {
  local hardened=0 failed=0

  if ! command -v chattr >/dev/null 2>&1; then
    echo "[SECURITY] chattr not available — relying on DAC + Landlock for .zeroclaw hardening" >&2
    return 0
  fi

  if chattr +i /sandbox/.zeroclaw 2>/dev/null; then
    hardened=$((hardened + 1))
  else
    failed=$((failed + 1))
  fi

  local entry
  for entry in /sandbox/.zeroclaw/*; do
    [ -L "$entry" ] || continue
    if chattr +i "$entry" 2>/dev/null; then
      hardened=$((hardened + 1))
    else
      failed=$((failed + 1))
    fi
  done

  if [ "$failed" -gt 0 ]; then
    echo "[SECURITY] Immutable hardening applied to $hardened path(s); $failed path(s) could not be hardened — continuing with DAC + Landlock" >&2
  elif [ "$hardened" -gt 0 ]; then
    echo "[SECURITY] Immutable hardening applied to /sandbox/.zeroclaw and validated symlinks" >&2
  fi
}

configure_messaging_channels() {
  # Channel entries are baked into config.toml at image build time via
  # NEMOCLAW_MESSAGING_CHANNELS_B64. Placeholder tokens flow through to
  # the L7 proxy for rewriting at egress.
  [ -n "${TELEGRAM_BOT_TOKEN:-}" ] || [ -n "${DISCORD_BOT_TOKEN:-}" ] || [ -n "${SLACK_BOT_TOKEN:-}" ] || return 0

  echo "[channels] Messaging channels active (baked at build time):" >&2
  [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && echo "[channels]   telegram" >&2
  [ -n "${DISCORD_BOT_TOKEN:-}" ] && echo "[channels]   discord" >&2
  [ -n "${SLACK_BOT_TOKEN:-}" ] && echo "[channels]   slack" >&2
  return 0
}

print_gateway_urls() {
  local local_url="http://127.0.0.1:${GATEWAY_PORT}"
  echo "[gateway] ZeroClaw API:  ${local_url}/v1" >&2
  echo "[gateway] Health:        ${local_url}/health" >&2
  echo "[gateway] Connect any OpenAI-compatible frontend to this endpoint." >&2
}

# Forward SIGTERM/SIGINT to the gateway process for graceful shutdown.
cleanup() {
  echo "[gateway] received signal, forwarding to gateway..." >&2
  local gateway_status=0
  kill -TERM "$GATEWAY_PID" 2>/dev/null || true
  wait "$GATEWAY_PID" 2>/dev/null || gateway_status=$?
  exit "$gateway_status"
}

# ── Proxy environment ────────────────────────────────────────────
# The OpenShell L7 proxy runs at 10.200.0.1:3128 inside sandboxes.
# Only set proxy env vars if the proxy is actually reachable — outside
# OpenShell (e.g. standalone Docker, Brev instances) the proxy does not
# exist and setting HTTPS_PROXY would hang all outbound HTTPS traffic.
PROXY_HOST="${NEMOCLAW_PROXY_HOST:-10.200.0.1}"
PROXY_PORT="${NEMOCLAW_PROXY_PORT:-3128}"
_PROXY_URL="http://${PROXY_HOST}:${PROXY_PORT}"
_NO_PROXY_VAL="localhost,127.0.0.1,::1,${PROXY_HOST}"

if curl -sf --max-time 2 --connect-timeout 2 "http://${PROXY_HOST}:${PROXY_PORT}/" >/dev/null 2>&1 \
  || nc -z -w 2 "$PROXY_HOST" "$PROXY_PORT" 2>/dev/null; then
  export HTTP_PROXY="$_PROXY_URL"
  export HTTPS_PROXY="$_PROXY_URL"
  export NO_PROXY="$_NO_PROXY_VAL"
  export http_proxy="$_PROXY_URL"
  export https_proxy="$_PROXY_URL"
  export no_proxy="$_NO_PROXY_VAL"
  echo "[proxy] OpenShell proxy detected at ${PROXY_HOST}:${PROXY_PORT}" >&2
else
  echo "[proxy] No proxy at ${PROXY_HOST}:${PROXY_PORT} — direct internet access" >&2
fi

_PROXY_MARKER_BEGIN="# nemoclaw-proxy-config begin"
_PROXY_MARKER_END="# nemoclaw-proxy-config end"
if [ -n "${HTTPS_PROXY:-}" ]; then
  _PROXY_SNIPPET="${_PROXY_MARKER_BEGIN}
export HTTP_PROXY=\"$_PROXY_URL\"
export HTTPS_PROXY=\"$_PROXY_URL\"
export NO_PROXY=\"$_NO_PROXY_VAL\"
export http_proxy=\"$_PROXY_URL\"
export https_proxy=\"$_PROXY_URL\"
export no_proxy=\"$_NO_PROXY_VAL\"
export ZEROCLAW_HOME=\"${ZEROCLAW_WRITABLE}\"
${_PROXY_MARKER_END}"
else
  _PROXY_SNIPPET="${_PROXY_MARKER_BEGIN}
export ZEROCLAW_HOME=\"${ZEROCLAW_WRITABLE}\"
${_PROXY_MARKER_END}"
fi

if [ "$(id -u)" -eq 0 ]; then
  _SANDBOX_HOME=$(getent passwd sandbox 2>/dev/null | cut -d: -f6)
  _SANDBOX_HOME="${_SANDBOX_HOME:-/sandbox}"
else
  _SANDBOX_HOME="${HOME:-/sandbox}"
fi

_write_proxy_snippet() {
  local target="$1"
  if [ -f "$target" ] && grep -qF "$_PROXY_MARKER_BEGIN" "$target" 2>/dev/null; then
    local tmp
    tmp="$(mktemp)"
    awk -v b="$_PROXY_MARKER_BEGIN" -v e="$_PROXY_MARKER_END" \
      '$0==b{s=1;next} $0==e{s=0;next} !s' "$target" >"$tmp"
    printf '%s\n' "$_PROXY_SNIPPET" >>"$tmp"
    cat "$tmp" >"$target"
    rm -f "$tmp"
    return 0
  fi
  printf '\n%s\n' "$_PROXY_SNIPPET" >>"$target"
}

if [ -w "$_SANDBOX_HOME" ]; then
  _write_proxy_snippet "${_SANDBOX_HOME}/.bashrc" 2>/dev/null || true
  _write_proxy_snippet "${_SANDBOX_HOME}/.profile" 2>/dev/null || true
fi

# ── Main ─────────────────────────────────────────────────────────

echo 'Setting up NemoClaw (ZeroClaw)...' >&2

# ── Non-root fallback ──────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  echo "[gateway] Running as non-root (uid=$(id -u)) — privilege separation disabled" >&2
  export HOME=/sandbox
  export ZEROCLAW_HOME="${ZEROCLAW_WRITABLE}"

  if ! verify_config_integrity; then
    echo "[SECURITY] Config integrity check failed — refusing to start (non-root mode)" >&2
    exit 1
  fi
  deploy_config_to_writable
  install_configure_guard
  configure_messaging_channels

  if [ ${#NEMOCLAW_CMD[@]} -gt 0 ]; then
    exec "${NEMOCLAW_CMD[@]}"
  fi

  touch /tmp/gateway.log
  chmod 600 /tmp/gateway.log

  ZEROCLAW_HOME="${ZEROCLAW_WRITABLE}" \
    nohup "$ZEROCLAW" gateway start --config-dir "${ZEROCLAW_WRITABLE}" >/tmp/gateway.log 2>&1 &
  GATEWAY_PID=$!
  echo "[gateway] zeroclaw gateway start launched (pid $GATEWAY_PID)" >&2
  trap cleanup SIGTERM SIGINT
  print_gateway_urls

  wait "$GATEWAY_PID"
  exit $?
fi

# ── Root path (full privilege separation via gosu) ─────────────

verify_config_integrity
deploy_config_to_writable
install_configure_guard
configure_messaging_channels

if [ ${#NEMOCLAW_CMD[@]} -gt 0 ]; then
  exec gosu sandbox "${NEMOCLAW_CMD[@]}"
fi

# SECURITY: Protect gateway log from sandbox user tampering.
# File stays root-owned so the shell redirect (running as root with
# cap_dac_override dropped) can open it. The gateway process inherits
# the open file descriptor via gosu — it does not need file ownership.
touch /tmp/gateway.log
chmod 600 /tmp/gateway.log

# Grant gateway user write access to writable data directories.
# ZeroClaw writes IDENTITY.md, logs, cache, and plugin state during runtime.
# The sandbox user retains group-write access for agent operations.
chown -R gateway:sandbox "${ZEROCLAW_WRITABLE}"
chmod -R g+w "${ZEROCLAW_WRITABLE}"

# Verify ALL symlinks in .zeroclaw point to expected .zeroclaw-data targets.
validate_zeroclaw_symlinks

# Lock .zeroclaw directory after validation.
harden_zeroclaw_symlinks

# Start the gateway as the 'gateway' user.
# ZEROCLAW_HOME alone is insufficient — ZeroClaw resolves config via
# ~/.zeroclaw/config.toml relative to the running user's home directory.
# Pass --config-dir explicitly so the gateway reads the deployed config
# from the writable data directory.
ZEROCLAW_HOME="${ZEROCLAW_WRITABLE}" \
  nohup gosu gateway "$ZEROCLAW" gateway start --config-dir "${ZEROCLAW_WRITABLE}" >/tmp/gateway.log 2>&1 &
GATEWAY_PID=$!
echo "[gateway] zeroclaw gateway start launched as 'gateway' user (pid $GATEWAY_PID)" >&2
trap cleanup SIGTERM SIGINT
print_gateway_urls

# Keep container running by waiting on the gateway process.
wait "$GATEWAY_PID"
