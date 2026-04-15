# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-FileCopyrightText: Copyright (c) 2026 Jason Perlow. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# ZeroClaw sandbox image — ZeroClaw + NemoClaw WASM plugin inside OpenShell
#
# Layers PR-specific code (WASM plugin, config, startup script) on top of the
# pre-built ZeroClaw base image. Mirrors the Hermes Dockerfile structure.

# Global ARG must precede all FROM instructions so Docker can resolve
# the parameterized base image in the second stage.
ARG BASE_IMAGE=ghcr.io/nvidia/nemoclaw/zeroclaw-sandbox-base:latest

# ── Stage 1: Compile NemoClaw WASM plugin ──────────────────────
FROM rust:1.87-bookworm AS wasm-builder

RUN rustup target add wasm32-wasip1

COPY agents/zeroclaw/plugin/ /build/
WORKDIR /build

RUN cargo build --target wasm32-wasip1 --release

# ── Stage 2: Application image ─────────────────────────────────
FROM ${BASE_IMAGE}

# Harden: remove unnecessary build tools and network probes
RUN (apt-get remove --purge -y gcc gcc-12 g++ g++-12 cpp cpp-12 make \
        netcat-openbsd netcat-traditional ncat 2>/dev/null || true) \
    && apt-get autoremove --purge -y \
    && rm -rf /var/lib/apt/lists/*

# Copy compiled NemoClaw WASM plugin
COPY --from=wasm-builder \
    /build/target/wasm32-wasip1/release/nemoclaw_zeroclaw_plugin.wasm \
    /opt/nemoclaw-zeroclaw-plugin/nemoclaw.wasm
COPY agents/zeroclaw/plugin/manifest.toml /opt/nemoclaw-zeroclaw-plugin/manifest.toml

# Copy config generation script
COPY agents/zeroclaw/generate-config.ts /opt/nemoclaw-generate-config.ts

# Copy blueprint (shared infrastructure)
COPY nemoclaw-blueprint/ /opt/nemoclaw-blueprint/

# Copy startup script
COPY agents/zeroclaw/start.sh /usr/local/bin/nemoclaw-start
RUN chmod 755 /usr/local/bin/nemoclaw-start

# Build args for config that varies per deployment.
ARG NEMOCLAW_MODEL=nvidia/llama-3.1-nemotron-70b-instruct
ARG NEMOCLAW_PROVIDER_KEY=compatible
ARG NEMOCLAW_INFERENCE_BASE_URL=https://inference.local/v1
ARG NEMOCLAW_MESSAGING_CHANNELS_B64=W10=
ARG NEMOCLAW_MESSAGING_ALLOWED_IDS_B64=e30=
ARG NEMOCLAW_BUILD_ID=default

# Promote build-args to env vars for the config generation script.
ENV NEMOCLAW_MODEL=${NEMOCLAW_MODEL} \
    NEMOCLAW_PROVIDER_KEY=${NEMOCLAW_PROVIDER_KEY} \
    NEMOCLAW_INFERENCE_BASE_URL=${NEMOCLAW_INFERENCE_BASE_URL} \
    NEMOCLAW_MESSAGING_CHANNELS_B64=${NEMOCLAW_MESSAGING_CHANNELS_B64} \
    NEMOCLAW_MESSAGING_ALLOWED_IDS_B64=${NEMOCLAW_MESSAGING_ALLOWED_IDS_B64}

WORKDIR /sandbox
USER sandbox

# Set up blueprint for local resolution
RUN mkdir -p /sandbox/.nemoclaw/blueprints/0.1.0 \
    && cp -r /opt/nemoclaw-blueprint/* /sandbox/.nemoclaw/blueprints/0.1.0/

# Generate ZeroClaw config.toml from build args.
# config.toml is immutable at runtime (Landlock read-only on /sandbox/.zeroclaw).
# SECURITY: Uses a separate script file instead of inline code to avoid
# code injection via build-arg interpolation (same concern as Hermes C-2).
RUN node --experimental-strip-types /opt/nemoclaw-generate-config.ts

# Install NemoClaw WASM plugin into ZeroClaw's plugin directory.
# ZeroClaw discovers plugins by scanning the plugins_dir for subdirectories
# containing manifest.toml + a .wasm file.
RUN mkdir -p /sandbox/.zeroclaw-data/plugins/nemoclaw \
    && cp /opt/nemoclaw-zeroclaw-plugin/nemoclaw.wasm \
          /sandbox/.zeroclaw-data/plugins/nemoclaw/nemoclaw.wasm \
    && cp /opt/nemoclaw-zeroclaw-plugin/manifest.toml \
          /sandbox/.zeroclaw-data/plugins/nemoclaw/manifest.toml

# Lock .zeroclaw via DAC: chown to root so sandbox user cannot modify config.
# Same pattern as Hermes — Landlock provides defense-in-depth.
# hadolint ignore=DL3002
USER root
RUN chown root:root /sandbox/.zeroclaw \
    && rm -rf /sandbox/.cache \
    && find /sandbox/.zeroclaw -mindepth 1 -maxdepth 1 -exec chown -h root:root {} + \
    && chmod 755 /sandbox/.zeroclaw \
    && chmod 444 /sandbox/.zeroclaw/config.toml

# Pin config hash at build time for integrity verification at startup.
RUN sha256sum /sandbox/.zeroclaw/config.toml \
    > /sandbox/.zeroclaw/.config-hash \
    && chmod 444 /sandbox/.zeroclaw/.config-hash \
    && chown root:root /sandbox/.zeroclaw/.config-hash

# start.sh handles privilege separation: runs as root initially to perform
# symlink validation and hardening, then drops to 'gateway' user via gosu
# for the agent process.
ENTRYPOINT ["/usr/local/bin/nemoclaw-start"]
CMD ["/bin/bash"]
