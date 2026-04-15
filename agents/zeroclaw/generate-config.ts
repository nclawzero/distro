// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-FileCopyrightText: Copyright (c) 2026 Jason Perlow. All rights reserved.
// SPDX-License-Identifier: Apache-2.0
//
// Generate ZeroClaw config.toml from NemoClaw build-arg env vars.
//
// Called at Docker image build time. Reads NEMOCLAW_* env vars and writes:
//   ~/.zeroclaw/config.toml  — ZeroClaw configuration (immutable at runtime)
//
// Sets what's required for ZeroClaw to run inside OpenShell:
//   - Model and inference endpoint via native provider name (e.g. "together")
//     with NEMOCLAW_PROVIDER_KEY build-arg mapped to the provider name.
//     The custom:<url> format has TLS issues inside containers — native
//     providers resolve their own endpoints and handle TLS correctly.
//   - Gateway bound to all interfaces on port 42617 (no socat needed — ZeroClaw
//     supports host = "[::]" natively, unlike Hermes)
//   - Messaging channel tokens (if configured during onboard)
//   - Plugin configuration to enable the NemoClaw WASM plugin
//   - Pairing disabled (NemoClaw manages sandbox access)

import { writeFileSync, chmodSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

// ZeroClaw gateway port. ZeroClaw binds directly to all interfaces (host = "[::]")
// so no socat forwarder is needed — OpenShell port-forwards straight to this port.
const GATEWAY_PORT = 42617;

const TOKEN_ENV: Record<string, string> = {
  telegram: "TELEGRAM_BOT_TOKEN",
  discord: "DISCORD_BOT_TOKEN",
  slack: "SLACK_BOT_TOKEN",
};

function main(): void {
  const model = process.env.NEMOCLAW_MODEL!;
  const baseUrl = process.env.NEMOCLAW_INFERENCE_BASE_URL!;

  const channelsB64 = process.env.NEMOCLAW_MESSAGING_CHANNELS_B64 || "W10=";
  const allowedIdsB64 = process.env.NEMOCLAW_MESSAGING_ALLOWED_IDS_B64 || "e30=";

  const msgChannels: string[] = JSON.parse(
    Buffer.from(channelsB64, "base64").toString("utf-8"),
  );
  const allowedIds: Record<string, (string | number)[]> = JSON.parse(
    Buffer.from(allowedIdsB64, "base64").toString("utf-8"),
  );

  const zeroclaw_home = join(homedir(), ".zeroclaw");

  // ── Resolve provider name ────────────────────────────────────
  // NEMOCLAW_PROVIDER_KEY maps to the ZeroClaw native provider name.
  // Native providers handle their own endpoint URLs and TLS, which
  // avoids transport errors that occur with custom:<url> in containers.
  // Falls back to custom:<url> for truly custom endpoints.
  const KNOWN_PROVIDERS: Record<string, string> = {
    "https://api.together.xyz/v1": "together",
    "https://api.together.xyz": "together",
    "https://api.groq.com/openai/v1": "groq",
    "https://api.openai.com/v1": "openai",
    "https://api.x.ai/v1": "xai",
    "https://integrate.api.nvidia.com/v1": "nvidia",
    "https://api.perplexity.ai": "perplexity",
    "http://localhost:11434": "ollama",
  };
  const providerKey = process.env.NEMOCLAW_PROVIDER_KEY || "compatible";
  const resolvedProvider = KNOWN_PROVIDERS[baseUrl] || `custom:${baseUrl}`;

  // ── Core config ────────────────────────────────────────────
  const lines: string[] = [
    `default_provider = ${tomlString(resolvedProvider)}`,
    `default_model = ${tomlString(model)}`,
    `default_temperature = 0.7`,
    "",
    "# ── Gateway ────────────────────────────────────────────",
    "[gateway]",
    `port = ${GATEWAY_PORT}`,
    `host = "[::]"`,
    "allow_public_bind = true",
    "require_pairing = false",
    "",
    "# ── NemoClaw WASM plugin ────────────────────────────────",
    "[plugins]",
    "enabled = true",
    `plugins_dir = "${join(homedir(), ".zeroclaw-data", "plugins")}"`,
  ];

  // ── Messaging channels ─────────────────────────────────────
  for (const ch of msgChannels) {
    if (ch in TOKEN_ENV) {
      lines.push("", `# ── ${ch[0].toUpperCase()}${ch.slice(1)} channel ─────────────────────────────────────`);
      lines.push(`[channel.${ch}]`);
      lines.push(`token = "openshell:resolve:env:${TOKEN_ENV[ch]}"`);
      if (ch in allowedIds && allowedIds[ch]?.length) {
        const ids = allowedIds[ch].map(String).join(", ");
        lines.push(`allowed_users = [${ids}]`);
      }
    }
  }

  const configPath = join(zeroclaw_home, "config.toml");
  writeFileSync(configPath, lines.join("\n") + "\n");
  chmodSync(configPath, 0o600);

  console.log(`[config] Wrote ${configPath} (model=${model}, provider=${resolvedProvider})`);
}

/** Quote a TOML string value. */
function tomlString(s: string): string {
  return JSON.stringify(s);
}

main();
