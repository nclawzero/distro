// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

let configDir = join(process.env.HOME ?? tmpdir(), ".nemoclaw");

export type EndpointType =
  | "build"
  | "openai"
  | "anthropic"
  | "gemini"
  | "ncp"
  | "nim-local"
  | "vllm"
  | "ollama"
  | "custom";

export interface NemoClawOnboardConfig {
  endpointType: EndpointType;
  endpointUrl: string;
  ncpPartner: string | null;
  model: string;
  profile: string;
  credentialEnv: string;
  provider?: string;
  providerLabel?: string;
  onboardedAt: string;
}

export function describeOnboardEndpoint(config: NemoClawOnboardConfig): string {
  if (config.endpointUrl === "https://inference.local/v1") {
    return "Managed Inference Route (inference.local)";
  }

  return `${config.endpointType} (${config.endpointUrl})`;
}

export function describeOnboardProvider(config: NemoClawOnboardConfig): string {
  if (config.providerLabel) {
    return config.providerLabel;
  }

  switch (config.endpointType) {
    case "build":
      return "NVIDIA Endpoints";
    case "openai":
      return "OpenAI";
    case "anthropic":
      return "Anthropic";
    case "gemini":
      return "Google Gemini";
    case "ollama":
      return "Local Ollama";
    case "vllm":
      return "Local vLLM";
    case "nim-local":
      return "Local NVIDIA NIM";
    case "ncp":
      return "NVIDIA Cloud Partner";
    case "custom":
      return "Other OpenAI-compatible endpoint";
    default:
      return "Unknown";
  }
}

let configDirCreated = false;

function ensureConfigDir(): void {
  if (configDirCreated) return;
  if (!existsSync(configDir)) {
    try {
      mkdirSync(configDir, { recursive: true });
    } catch {
      configDir = join(tmpdir(), ".nemoclaw");
      if (!existsSync(configDir)) {
        mkdirSync(configDir, { recursive: true });
      }
    }
  }
  configDirCreated = true;
}

function configPath(): string {
  return join(configDir, "config.json");
}

export function loadOnboardConfig(): NemoClawOnboardConfig | null {
  ensureConfigDir();
  const path = configPath();
  if (!existsSync(path)) {
    return null;
  }
  return JSON.parse(readFileSync(path, "utf-8")) as NemoClawOnboardConfig;
}

export function saveOnboardConfig(config: NemoClawOnboardConfig): void {
  ensureConfigDir();
  const path = configPath();
  writeFileSync(path, JSON.stringify(config, null, 2), { mode: 0o600 });
  // Belt-and-suspenders: explicit chmod in case umask or platform ignores the mode option
  try {
    chmodSync(path, 0o600);
  } catch {
    // Non-fatal — the mode option above covers most platforms
  }
}

export function clearOnboardConfig(): void {
  const path = configPath();
  if (existsSync(path)) {
    unlinkSync(path);
  }
}
