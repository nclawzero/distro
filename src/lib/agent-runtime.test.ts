// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-FileCopyrightText: Copyright (c) 2026 Jason Perlow. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

import { describe, expect, it, vi } from "vitest";

// Mock runner.ts to avoid its CJS require("./platform") chain which
// fails under Vitest (no compiled .js sibling in the source tree).
// Provide all exports used transitively by agent-runtime and agent-defs.
vi.mock("./runner", () => ({
  ROOT: "/mock/nemoclaw",
  SCRIPTS: "/mock/nemoclaw/scripts",
  shellQuote: (v: string) => `'${String(v).replace(/'/g, `'\\''`)}'`,
  run: vi.fn(),
  runCapture: vi.fn(() => ({ stdout: "", stderr: "", status: 0 })),
  runInteractive: vi.fn(),
  redact: (s: string) => s,
  validateName: vi.fn(),
}));

import {
  buildRecoveryScript,
  getAgentDisplayName,
  getHealthProbeUrl,
} from "./agent-runtime";
import type { AgentDefinition } from "./agent-defs";

// Minimal mock agent factory — only the fields used by agent-runtime functions.
function makeAgent(overrides: Partial<AgentDefinition>): AgentDefinition {
  return {
    name: "mock",
    displayName: "Mock",
    healthProbe: { url: "http://localhost:9999/health", port: 9999, timeout_seconds: 30 },
    configPaths: {
      immutableDir: "/sandbox/.mock",
      writableDir: "/sandbox/.mock-data",
      configFile: "config.json",
      envFile: null,
      format: "json",
    },
    homeEnvVar: null,
    binary_path: "/usr/local/bin/mock",
    gateway_command: "mock gateway run",
    ...overrides,
  } as unknown as AgentDefinition;
}

const ZEROCLAW_AGENT = makeAgent({
  name: "zeroclaw",
  displayName: "ZeroClaw",
  healthProbe: { url: "http://localhost:42617/health", port: 42617, timeout_seconds: 60 },
  configPaths: {
    immutableDir: "/sandbox/.zeroclaw",
    writableDir: "/sandbox/.zeroclaw-data",
    configFile: "config.toml",
    envFile: null,
    format: "toml",
  },
  homeEnvVar: "ZEROCLAW_HOME",
  binary_path: "/usr/local/bin/zeroclaw",
  gateway_command: "zeroclaw gateway start",
});

const HERMES_AGENT = makeAgent({
  name: "hermes",
  displayName: "Hermes Agent",
  healthProbe: { url: "http://localhost:8642/health", port: 8642, timeout_seconds: 90 },
  configPaths: {
    immutableDir: "/sandbox/.hermes",
    writableDir: "/sandbox/.hermes-data",
    configFile: "config.yaml",
    envFile: ".env",
    format: "yaml",
  },
  homeEnvVar: "HERMES_HOME",
  binary_path: "/usr/local/bin/hermes",
  gateway_command: "hermes gateway run",
});

// ── getHealthProbeUrl ──────────────────────────────────────────

describe("getHealthProbeUrl", () => {
  it("returns agent probe URL when agent is provided", () => {
    expect(getHealthProbeUrl(ZEROCLAW_AGENT)).toBe("http://localhost:42617/health");
    expect(getHealthProbeUrl(HERMES_AGENT)).toBe("http://localhost:8642/health");
  });

  it("returns OpenClaw default when agent is null", () => {
    const url = getHealthProbeUrl(null);
    expect(url).toMatch(/^http:\/\/127\.0\.0\.1:/);
  });
});

// ── getAgentDisplayName ────────────────────────────────────────

describe("getAgentDisplayName", () => {
  it("returns agent display name", () => {
    expect(getAgentDisplayName(ZEROCLAW_AGENT)).toBe("ZeroClaw");
    expect(getAgentDisplayName(HERMES_AGENT)).toBe("Hermes Agent");
  });

  it("returns OpenClaw for null", () => {
    expect(getAgentDisplayName(null)).toBe("OpenClaw");
  });
});

// ── buildRecoveryScript ────────────────────────────────────────

describe("buildRecoveryScript", () => {
  it("returns null for null agent (OpenClaw uses inline script)", () => {
    expect(buildRecoveryScript(null)).toBeNull();
  });

  it("includes ZEROCLAW_HOME export for zeroclaw agent", () => {
    const script = buildRecoveryScript(ZEROCLAW_AGENT)!;
    expect(script).toContain("export ZEROCLAW_HOME=/sandbox/.zeroclaw-data");
  });

  it("includes HERMES_HOME export for hermes agent", () => {
    const script = buildRecoveryScript(HERMES_AGENT)!;
    expect(script).toContain("export HERMES_HOME=/sandbox/.hermes-data");
  });

  it("omits home export for an agent with no home_env_var", () => {
    const agent = makeAgent({ homeEnvVar: null });
    const script = buildRecoveryScript(agent)!;
    expect(script).not.toContain("export ");
    // Should still include the gateway command
    expect(script).toContain("mock gateway run");
  });

  it("uses the agent gateway command", () => {
    expect(buildRecoveryScript(ZEROCLAW_AGENT)).toContain("zeroclaw gateway start");
    expect(buildRecoveryScript(HERMES_AGENT)).toContain("hermes gateway run");
  });

  it("includes a curl health check against the agent probe URL", () => {
    const script = buildRecoveryScript(ZEROCLAW_AGENT)!;
    expect(script).toContain("http://localhost:42617/health");
    expect(script).toContain("ALREADY_RUNNING");
  });

  it("includes binary existence check and AGENT_MISSING sentinel", () => {
    const script = buildRecoveryScript(ZEROCLAW_AGENT)!;
    expect(script).toContain("/usr/local/bin/zeroclaw");
    expect(script).toContain("AGENT_MISSING");
  });

  it("includes GATEWAY_FAILED sentinel for failed launch", () => {
    const script = buildRecoveryScript(ZEROCLAW_AGENT)!;
    expect(script).toContain("GATEWAY_FAILED");
    expect(script).toContain("GATEWAY_PID");
  });

  it("does not contain HERMES_HOME in zeroclaw script", () => {
    expect(buildRecoveryScript(ZEROCLAW_AGENT)).not.toContain("HERMES_HOME");
  });

  it("does not contain ZEROCLAW_HOME in hermes script", () => {
    expect(buildRecoveryScript(HERMES_AGENT)).not.toContain("ZEROCLAW_HOME");
  });
});
