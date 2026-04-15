#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-FileCopyrightText: Copyright (c) 2026 Jason Perlow. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Build stub Docker images for local installer testing on OmniStation.
#
# OmniStation blocks Docker Hub CDN and GitHub Releases CDN, so the real
# Dockerfile.base (which pulls node:22-slim and downloads zeroclaw/gosu
# from GitHub Releases) cannot run there. This script builds equivalent stub
# images from host Ubuntu 24.04 binaries using docker import.
#
# ┌─────────────────────────────────────────────────────────────────┐
# │  STUB IMAGES — NOT FOR PRODUCTION                               │
# │                                                                 │
# │  All images built here are labeled io.nemoclaw.stub=true and    │
# │  use a fake zeroclaw binary (Python HTTP health server) and a   │
# │  fake gosu (no-op privilege drop). They exist only to let the   │
# │  NemoClaw installer flow be tested end-to-end locally.          │
# │                                                                 │
# │  TODO (LIVE TEST on Brev):                                      │
# │    1. Delete stub images:                                       │
# │         docker rmi nemoclaw-stub-rootfs:latest                  │
# │         docker rmi ghcr.io/nvidia/nemoclaw/zeroclaw-sandbox-base:latest
# │    2. Run `nemoclaw onboard --agent zeroclaw` on the Brev system│
# │       (full network access — Docker Hub + GitHub Releases work) │
# │    3. Verify: real zeroclaw binary, real gosu, WASM plugin load │
# │    Brev system is provisioned for this purpose.                 │
# │                                                                 │
# │  PAT revocation reminder:                                       │
# │    A PAT was exposed in git history (commit 09a3a1ce).          │
# │    Revoke it at https://github.com/settings/tokens              │
# └─────────────────────────────────────────────────────────────────┘

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ROOTFS_TAG="nemoclaw-stub-rootfs:latest"
BASE_TAG="ghcr.io/nvidia/nemoclaw/zeroclaw-sandbox-base:latest"

WORK="$(mktemp -d "/tmp/nemoclaw-stub-XXXXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ── Helpers ───────────────────────────────────────────────────────
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*" >&2; }
ok() { printf '\033[1;32m  \xE2\x9C\x93 %s\033[0m\n' "$*" >&2; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*" >&2; }
die() {
  printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2
  exit 1
}

# copy_binary SRC [DST_DIR_IN_ROOTFS]
# Copies a binary and all its shared library dependencies into ROOTFS.
# Uses ldd to discover transitive shared lib requirements.
# Follows symlinks when copying libs (copies the real file, not the link).
ROOTFS="${WORK}/rootfs"

copy_binary() {
  local src="$1"
  local dst_dir="${ROOTFS}${2:-$(dirname "$src")}"
  [ -f "$src" ] || {
    warn "Skipping missing binary: $src"
    return 0
  }
  mkdir -p "$dst_dir"
  cp -f "$src" "$dst_dir/"

  # Parse ldd output for two forms:
  #   libfoo.so => /real/path/libfoo.so (0x...)
  #   /lib64/ld-linux-x86-64.so.2 (0x...)
  ldd "$src" 2>/dev/null | while IFS= read -r line; do
    local lib=""
    if [[ "$line" =~ '=>'[[:space:]]+(/[^[:space:]]+)[[:space:]] ]]; then
      lib="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]+(/[^[:space:]]+\.so[^[:space:]]*)[[:space:]] ]]; then
      lib="${BASH_REMATCH[1]}"
    fi
    [ -n "$lib" ] && [ -f "$lib" ] || continue
    local lib_dst
    lib_dst="${ROOTFS}$(dirname "$lib")"
    mkdir -p "$lib_dst"
    # -L: follow symlinks so we copy the real file
    cp -fL "$lib" "$lib_dst/"
  done
}

# ── 1. Build minimal rootfs from host binaries ────────────────────
step "Building minimal stub rootfs from host Ubuntu 24.04 binaries"

mkdir -p \
  "${ROOTFS}/usr/local/bin" \
  "${ROOTFS}/usr/local/sbin" \
  "${ROOTFS}/usr/bin" \
  "${ROOTFS}/usr/sbin" \
  "${ROOTFS}/usr/lib/x86_64-linux-gnu" \
  "${ROOTFS}/lib/x86_64-linux-gnu" \
  "${ROOTFS}/lib64" \
  "${ROOTFS}/bin" \
  "${ROOTFS}/sbin" \
  "${ROOTFS}/tmp" \
  "${ROOTFS}/proc" \
  "${ROOTFS}/sys" \
  "${ROOTFS}/dev" \
  "${ROOTFS}/etc/alternatives" \
  "${ROOTFS}/var/run" \
  "${ROOTFS}/run" \
  "${ROOTFS}/home" \
  "${ROOTFS}/root" \
  "${ROOTFS}/sandbox"

# Dynamic linker — must be present for any dynamically-linked binary to run
LD_LINUX="$(ldconfig -p 2>/dev/null | grep -oP '/[^ ]*ld-linux-x86-64[^ ]*' | head -1 || true)"
if [ -n "$LD_LINUX" ] && [ -f "$LD_LINUX" ]; then
  mkdir -p "${ROOTFS}/lib64"
  cp -fL "$LD_LINUX" "${ROOTFS}/lib64/ld-linux-x86-64.so.2"
  ok "Copied dynamic linker: $LD_LINUX"
else
  warn "Could not locate ld-linux-x86-64.so.2 via ldconfig — dynamic linking may fail"
fi

# Core shell and utilities
for bin in \
  /bin/bash /bin/sh /usr/bin/env \
  /usr/bin/python3 \
  /usr/bin/awk /usr/bin/gawk \
  /usr/bin/sed /usr/bin/grep \
  /usr/bin/cut /usr/bin/head /usr/bin/tail \
  /usr/bin/cat /usr/bin/tee \
  /usr/bin/wc /usr/bin/sort /usr/bin/uniq \
  /usr/bin/find /usr/bin/xargs \
  /usr/bin/mktemp /usr/bin/realpath \
  /usr/bin/id /usr/bin/getent \
  /usr/bin/sha256sum /usr/bin/md5sum \
  /usr/bin/curl /usr/bin/wget \
  /usr/bin/sleep /usr/bin/date /usr/bin/touch \
  /usr/bin/chmod /usr/bin/chown /usr/bin/chgrp \
  /usr/bin/cp /usr/bin/mv /usr/bin/rm /usr/bin/rmdir \
  /usr/bin/mkdir /usr/bin/ln /usr/bin/readlink \
  /usr/bin/install /usr/bin/basename /usr/bin/dirname \
  /usr/bin/true /usr/bin/false \
  /usr/sbin/groupadd /usr/sbin/useradd /usr/sbin/nologin \
  /usr/sbin/usermod /usr/sbin/groupmod \
  /usr/bin/nohup /usr/bin/kill; do
  copy_binary "$bin"
done

# Node.js — install under /usr/local/bin (matches PATH priority)
if [ -f /usr/bin/node ]; then
  copy_binary /usr/bin/node /usr/local/bin
  ok "Copied Node.js $(node --version) to /usr/local/bin/node"
else
  warn "node not found — generate-config.ts will not work"
fi

# Python3 shared libs (ldd usually gets them, but ensure libpython is present)
PY3="$(command -v python3 || true)"
if [ -n "$PY3" ]; then
  PY_VER="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
  PY_LIB="/usr/lib/python${PY_VER}"
  PY_LIB_DYNLOAD="/usr/lib/python${PY_VER}/lib-dynload"
  PY_STDLIB="/usr/lib/python3"
  for lib_dir in "$PY_LIB" "$PY_STDLIB"; do
    if [ -d "$lib_dir" ]; then
      mkdir -p "${ROOTFS}${lib_dir}"
      # Copy stdlib modules needed by the fake zeroclaw (http.server, json, os, sys)
      cp -rL "$lib_dir" "${ROOTFS}$(dirname "$lib_dir")/" 2>/dev/null || true
    fi
  done
  # lib-dynload for socket, _json, etc.
  if [ -d "$PY_LIB_DYNLOAD" ]; then
    mkdir -p "${ROOTFS}${PY_LIB_DYNLOAD}"
    cp -rL "$PY_LIB_DYNLOAD"/*.so "${ROOTFS}${PY_LIB_DYNLOAD}/" 2>/dev/null || true
  fi
  ok "Copied Python ${PY_VER} stdlib"
fi

# /etc/passwd, group, shadow — minimal entries
cat >"${ROOTFS}/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
EOF
cat >"${ROOTFS}/etc/group" <<'EOF'
root:x:0:
daemon:x:1:
EOF
cat >"${ROOTFS}/etc/shadow" <<'EOF'
root:*:19000:0:99999:7:::
EOF
chmod 640 "${ROOTFS}/etc/shadow"

echo "stub-sandbox" >"${ROOTFS}/etc/hostname"
printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' >"${ROOTFS}/etc/resolv.conf"
printf '/lib/x86_64-linux-gnu\n/usr/lib/x86_64-linux-gnu\n/usr/local/lib\n' \
  >"${ROOTFS}/etc/ld.so.conf"

# Run ldconfig inside the rootfs to generate ld.so.cache
if command -v ldconfig >/dev/null 2>&1; then
  ldconfig -r "${ROOTFS}" 2>/dev/null || warn "ldconfig failed (non-fatal)"
fi

# Ubuntu 24.04 uses merged /usr: /bin, /sbin, /lib are symlinks → /usr/*
# Docker import preserves symlinks so set them up here
for d in bin sbin lib; do
  if [ ! -L "${ROOTFS}/$d" ] && [ -d "${ROOTFS}/usr/$d" ]; then
    # Only create symlink if the non-usr dir is empty (we already populated /usr/*)
    rmdir "${ROOTFS}/$d" 2>/dev/null || true
    ln -sfn "usr/$d" "${ROOTFS}/$d"
  fi
done

ok "Rootfs built: $(du -sh "${ROOTFS}" | cut -f1)"

# ── 2. Import rootfs as nemoclaw-stub-rootfs:latest ───────────────
step "Importing stub rootfs as Docker image: ${ROOTFS_TAG}"

# Normalize ownership and permissions before import.
# Files were copied as the current user (not root), so their UID/GID on the
# host is non-zero. Inside Docker, 'sandbox' (uid 1000) would then fall into
# the 'other' permission class for files owned by the build user's UID,
# hitting "Permission denied" when trying to exec any binary.
# Fix: chmod system dirs/libs to be world-readable, then force UID/GID 0
# in the tar stream so Docker sees all files as root-owned.
chmod -R a+rX "${ROOTFS}/usr" 2>/dev/null || true
chmod -R a+rX "${ROOTFS}/lib" 2>/dev/null || true
chmod -R a+rX "${ROOTFS}/lib64" 2>/dev/null || true
chmod -R a+rX "${ROOTFS}/bin" 2>/dev/null || true
chmod -R a+rX "${ROOTFS}/sbin" 2>/dev/null || true
chmod -R a+rX "${ROOTFS}/etc" 2>/dev/null || true
# Keep /etc/shadow restricted — it should not be world-readable
chmod 640 "${ROOTFS}/etc/shadow" 2>/dev/null || true

tar -C "${ROOTFS}" -c . \
  --owner=root:0 --group=root:0 \
  | docker import \
    --change "ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    --change "ENV HOME=/root" \
    --change "LABEL io.nemoclaw.stub=true" \
    --change "LABEL io.nemoclaw.stub.reason=host-rootfs-for-omnistation" \
    - "${ROOTFS_TAG}"

ok "Imported ${ROOTFS_TAG}"

# ── 3. Build zeroclaw-sandbox-base (stub) ─────────────────────────
step "Building ${BASE_TAG} using Dockerfile.stub.base"

docker build \
  --file "${REPO_ROOT}/agents/zeroclaw/Dockerfile.stub.base" \
  --tag "${BASE_TAG}" \
  --label "io.nemoclaw.stub=true" \
  --label "io.nemoclaw.stub.reason=zeroclaw-base-without-docker-hub" \
  "${REPO_ROOT}"

ok "Built ${BASE_TAG}"

# ── 4. Summary ────────────────────────────────────────────────────
step "Stub images ready"

echo ""
docker images --filter "label=io.nemoclaw.stub=true" \
  --format "  {{.Repository}}:{{.Tag}}  {{.Size}}"
echo ""

cat <<'SUMMARY'
┌─────────────────────────────────────────────────────────────────┐
│  STUB IMAGES BUILT — local installer testing enabled            │
│                                                                 │
│  The NemoClaw installer will now find:                          │
│    ghcr.io/nvidia/nemoclaw/zeroclaw-sandbox-base:latest         │
│  and skip the base image build step.                            │
│                                                                 │
│  To build the full sandbox image (Dockerfile.stub), run:        │
│    nemoclaw onboard --agent zeroclaw                            │
│  or manually:                                                   │
│    docker build -f agents/zeroclaw/Dockerfile.stub \            │
│      -t ghcr.io/nvidia/nemoclaw/zeroclaw-sandbox:local .        │
│                                                                 │
│  Stub zeroclaw binary: serves GET /health on port 42617         │
│  Health probe: http://localhost:42617/health → {"status":"ok"}  │
│                                                                 │
│  TODO (LIVE TEST on Brev):                                      │
│    1. Delete stub images:                                       │
│         docker rmi nemoclaw-stub-rootfs:latest                  │
│         docker rmi ghcr.io/nvidia/nemoclaw/zeroclaw-sandbox-base:latest
│    2. Run: nemoclaw onboard --agent zeroclaw                    │
│       (pulls real node:22-slim + real zeroclaw binary)          │
│    3. Verify health probe, config hash, WASM plugin load        │
│    Brev system is provisioned for this purpose.                 │
│                                                                 │
│  PAT revocation reminder:                                       │
│    A PAT was exposed in git history (commit 09a3a1ce).          │
│    Revoke it at https://github.com/settings/tokens              │
└─────────────────────────────────────────────────────────────────┘
SUMMARY
