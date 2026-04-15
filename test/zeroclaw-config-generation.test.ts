// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-FileCopyrightText: Copyright (c) 2026 Jason Perlow. All rights reserved.
// SPDX-License-Identifier: Apache-2.0
//
// Tests for agents/zeroclaw/generate-config.ts — the build-time config
// generation script that reads NEMOCLAW_* env vars and writes config.toml.
//
// Tests spawn the script as a subprocess with controlled env vars and
// inspect the generated output for structural correctness.

// @ts-nocheck
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

const GENERATE_CONFIG_SCRIPT = path.join(
  import.meta.dirname,
  "..",
  "agents",
  "zeroclaw",
  "generate-config.ts",
);

// ── Helpers ────────────────────────────────────────────────────────

let tmpHome: string;

beforeEach(() => {
  tmpHome = fs.mkdtempSync(path.join(os.tmpdir(), "zeroclaw-cfg-test-"));
  // Create the .zeroclaw directory that the script writes into
  fs.mkdirSync(path.join(tmpHome, ".zeroclaw"), { recursive: true });
  fs.mkdirSync(path.join(tmpHome, ".zeroclaw-data", "plugins"), {
    recursive: true,
  });
});

afterEach(() => {
  fs.rmSync(tmpHome, { recursive: true, force: true });
});

/**
 * Run generate-config.ts with the given env vars.
 * Returns { stdout, stderr, status, configToml }.
 */
function runGenerateConfig(
  envOverrides: Record<string, string> = {},
): {
  stdout: string;
  stderr: string;
  status: number | null;
  configToml: string | null;
} {
  // Find node 22 — prefer /opt/homebrew path, fall back to PATH
  const nodeBin =
    fs.existsSync("/opt/homebrew/opt/node@22/bin/node")
      ? "/opt/homebrew/opt/node@22/bin/node"
      : "node";

  const env: Record<string, string> = {
    // Minimal env: HOME set to our temp dir, PATH for node
    PATH: process.env.PATH || "/usr/local/bin:/usr/bin:/bin",
    HOME: tmpHome,
    // Required env vars with defaults
    NEMOCLAW_MODEL: "test/model-7b",
    NEMOCLAW_INFERENCE_BASE_URL: "https://api.together.xyz/v1",
    NEMOCLAW_PROVIDER_KEY: "compatible",
    NEMOCLAW_MESSAGING_CHANNELS_B64: "W10=", // base64("[]")
    NEMOCLAW_MESSAGING_ALLOWED_IDS_B64: "e30=", // base64("{}")
    ...envOverrides,
  };

  const result = spawnSync(
    nodeBin,
    ["--experimental-strip-types", GENERATE_CONFIG_SCRIPT],
    {
      encoding: "utf-8",
      stdio: ["pipe", "pipe", "pipe"],
      env,
      timeout: 15000,
    },
  );

  const configPath = path.join(tmpHome, ".zeroclaw", "config.toml");
  let configToml: string | null = null;
  if (fs.existsSync(configPath)) {
    configToml = fs.readFileSync(configPath, "utf-8");
  }

  return {
    stdout: result.stdout || "",
    stderr: result.stderr || "",
    status: result.status,
    configToml,
  };
}

// ═══════════════════════════════════════════════════════════════════
// 1. Valid TOML output
// ═══════════════════════════════════════════════════════════════════
describe("valid TOML output", () => {
  it("generates a config.toml file", () => {
    const { status, configToml } = runGenerateConfig();
    expect(status).toBe(0);
    expect(configToml).toBeTruthy();
  });

  it("output has valid TOML key = value structure", () => {
    const { configToml } = runGenerateConfig();
    expect(configToml).toBeTruthy();

    // Check basic TOML structure: key = value lines, [section] headers, comments
    const lines = configToml!.split("\n");
    for (const line of lines) {
      const trimmed = line.trim();
      if (trimmed === "" || trimmed.startsWith("#")) continue;
      // Should be either a [section] header, [[array]] header, or key = value
      const isSection = /^\[+[a-zA-Z0-9_.]+\]+$/.test(trimmed);
      const isKeyValue = /^[a-zA-Z_][a-zA-Z0-9_]*\s*=\s*.+$/.test(trimmed);
      expect(
        isSection || isKeyValue,
      ).toBe(true);
    }
  });

  it("default_model value is properly TOML-quoted", () => {
    const { configToml } = runGenerateConfig({
      NEMOCLAW_MODEL: "nvidia/llama-3.1-nemotron-70b-instruct",
    });
    expect(configToml).toBeTruthy();
    // The model value should be in double quotes (TOML string)
    expect(configToml).toMatch(
      /default_model\s*=\s*"nvidia\/llama-3\.1-nemotron-70b-instruct"/,
    );
  });
});

// ═══════════════════════════════════════════════════════════════════
// 2. Provider URL mapping
// ═══════════════════════════════════════════════════════════════════
describe("provider URL mapping", () => {
  // These mappings are defined in generate-config.ts KNOWN_PROVIDERS
  const KNOWN_MAPPINGS: [string, string][] = [
    ["https://api.together.xyz/v1", "together"],
    ["https://api.together.xyz", "together"],
    ["https://api.groq.com/openai/v1", "groq"],
    ["https://api.openai.com/v1", "openai"],
    ["https://api.x.ai/v1", "xai"],
    ["https://integrate.api.nvidia.com/v1", "nvidia"],
    ["https://api.perplexity.ai", "perplexity"],
    ["http://localhost:11434", "ollama"],
  ];

  for (const [url, expectedProvider] of KNOWN_MAPPINGS) {
    it(`maps ${url} to provider "${expectedProvider}"`, () => {
      const { status, configToml } = runGenerateConfig({
        NEMOCLAW_INFERENCE_BASE_URL: url,
      });
      expect(status).toBe(0);
      expect(configToml).toBeTruthy();
      expect(configToml).toMatch(
        new RegExp(`default_provider\\s*=\\s*"${expectedProvider}"`),
      );
    });
  }

  it("falls back to custom:<url> for unknown endpoints", () => {
    const customUrl = "https://my-custom-endpoint.example.com/v1";
    const { status, configToml } = runGenerateConfig({
      NEMOCLAW_INFERENCE_BASE_URL: customUrl,
    });
    expect(status).toBe(0);
    expect(configToml).toBeTruthy();
    expect(configToml).toContain(`custom:${customUrl}`);
  });
});

// ═══════════════════════════════════════════════════════════════════
// 3. Model routes / config sections present
// ═══════════════════════════════════════════════════════════════════
describe("config structure", () => {
  it("output contains default_provider assignment", () => {
    const { configToml } = runGenerateConfig();
    expect(configToml).toMatch(/^default_provider\s*=/m);
  });

  it("output contains default_model assignment", () => {
    const { configToml } = runGenerateConfig();
    expect(configToml).toMatch(/^default_model\s*=/m);
  });

  it("output contains default_temperature assignment", () => {
    const { configToml } = runGenerateConfig();
    expect(configToml).toMatch(/^default_temperature\s*=/m);
  });
});

// ═══════════════════════════════════════════════════════════════════
// 4. Gateway config
// ═══════════════════════════════════════════════════════════════════
describe("gateway configuration", () => {
  it("output contains [gateway] section", () => {
    const { configToml } = runGenerateConfig();
    expect(configToml).toMatch(/^\[gateway\]$/m);
  });

  it("gateway port is 42617", () => {
    const { configToml } = runGenerateConfig();
    expect(configToml).toMatch(/port\s*=\s*42617/);
  });

  it('gateway binds to all interfaces (host = "[::]")', () => {
    const { configToml } = runGenerateConfig();
    expect(configToml).toMatch(/host\s*=\s*"\[::\]"/);
  });

  it("gateway has allow_public_bind = true", () => {
    const { configToml } = runGenerateConfig();
    expect(configToml).toMatch(/allow_public_bind\s*=\s*true/);
  });

  it("gateway has require_pairing = false (sandbox managed by NemoClaw)", () => {
    const { configToml } = runGenerateConfig();
    expect(configToml).toMatch(/require_pairing\s*=\s*false/);
  });
});

// ═══════════════════════════════════════════════════════════════════
// 5. Missing env vars behavior
// ═══════════════════════════════════════════════════════════════════
describe("missing env vars", () => {
  it("NEMOCLAW_MESSAGING_CHANNELS_B64 defaults to empty array (W10=)", () => {
    // Omit the channels env var entirely — script should use default "W10="
    const { status, configToml } = runGenerateConfig({
      NEMOCLAW_MESSAGING_CHANNELS_B64: "",
    });
    // The script uses: process.env.NEMOCLAW_MESSAGING_CHANNELS_B64 || "W10="
    // An empty string is falsy, so it falls back to "W10=" (empty JSON array)
    expect(status).toBe(0);
    expect(configToml).toBeTruthy();
    // No [channel.*] sections should be present when channels list is empty
    expect(configToml).not.toMatch(/^\[channel\./m);
  });

  it("NEMOCLAW_MESSAGING_ALLOWED_IDS_B64 defaults to empty object (e30=)", () => {
    const { status, configToml } = runGenerateConfig({
      NEMOCLAW_MESSAGING_ALLOWED_IDS_B64: "",
    });
    expect(status).toBe(0);
    expect(configToml).toBeTruthy();
  });

  it("NEMOCLAW_PROVIDER_KEY defaults to 'compatible' when unset", () => {
    // The script reads: process.env.NEMOCLAW_PROVIDER_KEY || "compatible"
    const { status, configToml } = runGenerateConfig({
      NEMOCLAW_PROVIDER_KEY: "",
    });
    expect(status).toBe(0);
    expect(configToml).toBeTruthy();
  });
});

// ═══════════════════════════════════════════════════════════════════
// 6. Base64 channel decode
// ═══════════════════════════════════════════════════════════════════
describe("base64 channel decoding", () => {
  it("decodes NEMOCLAW_MESSAGING_CHANNELS_B64 and generates channel sections", () => {
    // Encode ["telegram"] as base64
    const channelsB64 = Buffer.from(JSON.stringify(["telegram"])).toString(
      "base64",
    );
    const { status, configToml } = runGenerateConfig({
      NEMOCLAW_MESSAGING_CHANNELS_B64: channelsB64,
    });
    expect(status).toBe(0);
    expect(configToml).toBeTruthy();
    expect(configToml).toMatch(/^\[channel\.telegram\]$/m);
    expect(configToml).toContain(
      'token = "openshell:resolve:env:TELEGRAM_BOT_TOKEN"',
    );
  });

  it("decodes multiple channels", () => {
    const channelsB64 = Buffer.from(
      JSON.stringify(["telegram", "discord", "slack"]),
    ).toString("base64");
    const { status, configToml } = runGenerateConfig({
      NEMOCLAW_MESSAGING_CHANNELS_B64: channelsB64,
    });
    expect(status).toBe(0);
    expect(configToml).toBeTruthy();
    expect(configToml).toMatch(/^\[channel\.telegram\]$/m);
    expect(configToml).toMatch(/^\[channel\.discord\]$/m);
    expect(configToml).toMatch(/^\[channel\.slack\]$/m);
  });

  it("decodes allowed IDs and adds allowed_users to channel config", () => {
    const channelsB64 = Buffer.from(JSON.stringify(["telegram"])).toString(
      "base64",
    );
    const allowedIdsB64 = Buffer.from(
      JSON.stringify({ telegram: [123456, 789012] }),
    ).toString("base64");
    const { status, configToml } = runGenerateConfig({
      NEMOCLAW_MESSAGING_CHANNELS_B64: channelsB64,
      NEMOCLAW_MESSAGING_ALLOWED_IDS_B64: allowedIdsB64,
    });
    expect(status).toBe(0);
    expect(configToml).toBeTruthy();
    expect(configToml).toMatch(/^\[channel\.telegram\]$/m);
    expect(configToml).toMatch(/allowed_users\s*=\s*\[123456,\s*789012\]/);
  });

  it("ignores unknown channel names not in TOKEN_ENV mapping", () => {
    const channelsB64 = Buffer.from(
      JSON.stringify(["telegram", "unknown_platform"]),
    ).toString("base64");
    const { status, configToml } = runGenerateConfig({
      NEMOCLAW_MESSAGING_CHANNELS_B64: channelsB64,
    });
    expect(status).toBe(0);
    expect(configToml).toBeTruthy();
    expect(configToml).toMatch(/^\[channel\.telegram\]$/m);
    // unknown_platform should not generate a section
    expect(configToml).not.toMatch(/^\[channel\.unknown_platform\]$/m);
  });

  it("produces no channel sections when channels array is empty", () => {
    const channelsB64 = Buffer.from(JSON.stringify([])).toString("base64");
    const { status, configToml } = runGenerateConfig({
      NEMOCLAW_MESSAGING_CHANNELS_B64: channelsB64,
    });
    expect(status).toBe(0);
    expect(configToml).toBeTruthy();
    expect(configToml).not.toMatch(/^\[channel\./m);
  });
});

// ═══════════════════════════════════════════════════════════════════
// 7. Plugin configuration
// ═══════════════════════════════════════════════════════════════════
describe("plugin configuration", () => {
  it("output contains [plugins] section", () => {
    const { configToml } = runGenerateConfig();
    expect(configToml).toMatch(/^\[plugins\]$/m);
  });

  it("plugins are enabled", () => {
    const { configToml } = runGenerateConfig();
    expect(configToml).toMatch(/enabled\s*=\s*true/);
  });

  it("plugins_dir points to .zeroclaw-data/plugins", () => {
    const { configToml } = runGenerateConfig();
    expect(configToml).toMatch(/plugins_dir\s*=\s*".*\.zeroclaw-data\/plugins"/);
  });
});

// ═══════════════════════════════════════════════════════════════════
// 8. Source file structural checks
// ═══════════════════════════════════════════════════════════════════
describe("generate-config.ts source integrity", () => {
  const source = fs.readFileSync(GENERATE_CONFIG_SCRIPT, "utf-8");

  it("reads env vars via process.env (not interpolation)", () => {
    expect(source).toContain("process.env.NEMOCLAW_MODEL");
    expect(source).toContain("process.env.NEMOCLAW_INFERENCE_BASE_URL");
    expect(source).toContain("process.env.NEMOCLAW_MESSAGING_CHANNELS_B64");
  });

  it("defines KNOWN_PROVIDERS mapping", () => {
    expect(source).toContain("KNOWN_PROVIDERS");
  });

  it("uses GATEWAY_PORT constant set to 42617", () => {
    expect(source).toMatch(/GATEWAY_PORT\s*=\s*42617/);
  });

  it("has SPDX license header", () => {
    expect(source).toContain("SPDX-License-Identifier: Apache-2.0");
  });
});
