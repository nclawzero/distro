// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0
//
// P0 Security test: subprocess environment allowlist.
//
// buildSubprocessEnv() is the core credential-isolation boundary. It must:
//   1. Block all non-whitelisted env vars (prevents API key leakage)
//   2. Allow only explicitly listed system/toolchain vars
//   3. Merge injected credentials via `extra` parameter
//   4. Never return undefined values

import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { buildSubprocessEnv } from "./subprocess-env.js";

// ── Synthetic credentials (assembled at runtime to avoid gitleaks) ──

const FAKE_NVIDIA_KEY = "nvapi-" + "ABCDEFghijklMNOP1234567890abcdef";
const FAKE_GITHUB_TOKEN = "ghp_" + "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmn";
const FAKE_AWS_ACCESS = "AKIA" + "IOSFODNN7EXAMPLE";
const FAKE_AWS_SECRET = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY";
const FAKE_OPENAI_KEY = "sk-" + "abc123def456ghi789jkl012mno345pqr678";
const FAKE_ANTHROPIC_KEY = "sk-ant-" + "api03-ABCDEFghijklMNOPqrstuv";
const FAKE_HF_TOKEN = "hf_" + "ABCDEFghijklMNOPqrstuvwxyz1234";
const FAKE_SLACK_TOKEN = "xoxb-" + "1234567890-1234567890123-abcdefGHIJKL";

// ── Dangerous env vars that MUST be blocked ──

const CREDENTIAL_ENV_VARS: Record<string, string> = {
  NVIDIA_API_KEY: FAKE_NVIDIA_KEY,
  GITHUB_TOKEN: FAKE_GITHUB_TOKEN,
  AWS_ACCESS_KEY_ID: FAKE_AWS_ACCESS,
  AWS_SECRET_ACCESS_KEY: FAKE_AWS_SECRET,
  OPENAI_API_KEY: FAKE_OPENAI_KEY,
  ANTHROPIC_API_KEY: FAKE_ANTHROPIC_KEY,
  HF_TOKEN: FAKE_HF_TOKEN,
  SLACK_BOT_TOKEN: FAKE_SLACK_TOKEN,
  DISCORD_BOT_TOKEN: "MTIzNDU2Nzg5MDEyMzQ1Njc4OQ.FAKE.token",
  TELEGRAM_BOT_TOKEN: "1234567890:ABCdefGHIjklMNOpqrsTUVwxyz",
  BEDROCK_API_KEY: "bedrock-fake-key-1234567890",
  GOOGLE_API_KEY: "AIzaSy" + "FAKE_KEY_1234567890abcdef",
  DATABASE_URL: "postgres://user:password@localhost:5432/db",
  SECRET_KEY: "super-secret-value-that-must-not-leak",
  PRIVATE_KEY: "-----BEGIN RSA PRIVATE KEY-----FAKE",
  NPM_TOKEN: "npm_" + "ABCDEFghijklMNOPqrstuvwxyz12",
};

// ── Allowed env vars that MUST pass through ──

const ALLOWED_NAMES = [
  "HOME", "USER", "LOGNAME", "SHELL", "PATH", "TERM", "HOSTNAME", "NODE_ENV",
  "TMPDIR", "TMP", "TEMP",
  "LANG",
  "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy",
  "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS",
  "DOCKER_HOST", "KUBECONFIG", "SSH_AUTH_SOCK", "RUST_LOG", "RUST_BACKTRACE",
];

const ALLOWED_PREFIXED = [
  "LC_ALL", "LC_CTYPE", "LC_MESSAGES",
  "XDG_RUNTIME_DIR", "XDG_DATA_HOME", "XDG_CONFIG_HOME",
  "OPENSHELL_SANDBOX_ID", "OPENSHELL_TOKEN",
  "GRPC_DNS_RESOLVER", "GRPC_VERBOSITY",
];

describe("subprocess-env: buildSubprocessEnv()", () => {
  const savedEnv = { ...process.env };

  beforeEach(() => {
    // Reset to a clean slate — only inject what each test needs
    for (const key of Object.keys(process.env)) {
      delete process.env[key];
    }
  });

  afterEach(() => {
    // Restore original environment
    for (const key of Object.keys(process.env)) {
      delete process.env[key];
    }
    Object.assign(process.env, savedEnv);
  });

  // ── P0: Credential blocking ──────────────────────────────────

  describe("blocks credential env vars", () => {
    for (const [name, value] of Object.entries(CREDENTIAL_ENV_VARS)) {
      it(`blocks ${name}`, () => {
        process.env[name] = value;
        process.env.HOME = "/home/test"; // need at least one allowed var
        const env = buildSubprocessEnv();
        expect(env).not.toHaveProperty(name);
      });
    }
  });

  describe("blocks credential vars even when mixed with allowed vars", () => {
    it("returns allowed vars but strips credentials from a realistic env", () => {
      // Simulate a realistic process.env
      process.env.HOME = "/home/user";
      process.env.PATH = "/usr/bin:/bin";
      process.env.SHELL = "/bin/bash";
      process.env.NVIDIA_API_KEY = FAKE_NVIDIA_KEY;
      process.env.AWS_SECRET_ACCESS_KEY = FAKE_AWS_SECRET;
      process.env.OPENAI_API_KEY = FAKE_OPENAI_KEY;
      process.env.LC_ALL = "en_US.UTF-8";
      process.env.XDG_RUNTIME_DIR = "/run/user/1000";

      const env = buildSubprocessEnv();

      expect(env.HOME).toBe("/home/user");
      expect(env.PATH).toBe("/usr/bin:/bin");
      expect(env.SHELL).toBe("/bin/bash");
      expect(env.LC_ALL).toBe("en_US.UTF-8");
      expect(env.XDG_RUNTIME_DIR).toBe("/run/user/1000");
      expect(env).not.toHaveProperty("NVIDIA_API_KEY");
      expect(env).not.toHaveProperty("AWS_SECRET_ACCESS_KEY");
      expect(env).not.toHaveProperty("OPENAI_API_KEY");
    });
  });

  // ── P0: Allowlist correctness ─────────────────────────────────

  describe("allows named system/toolchain vars", () => {
    for (const name of ALLOWED_NAMES) {
      it(`allows ${name}`, () => {
        process.env[name] = "test-value";
        const env = buildSubprocessEnv();
        expect(env[name]).toBe("test-value");
      });
    }
  });

  describe("allows prefixed vars", () => {
    for (const name of ALLOWED_PREFIXED) {
      it(`allows ${name}`, () => {
        process.env[name] = "test-value";
        const env = buildSubprocessEnv();
        expect(env[name]).toBe("test-value");
      });
    }
  });

  // ── P0: Extra parameter (credential injection) ───────────────

  describe("extra parameter merges correctly", () => {
    it("injects extra credentials into output", () => {
      process.env.HOME = "/home/test";
      const env = buildSubprocessEnv({ OPENAI_API_KEY: FAKE_OPENAI_KEY });
      expect(env.OPENAI_API_KEY).toBe(FAKE_OPENAI_KEY);
      expect(env.HOME).toBe("/home/test");
    });

    it("extra overrides blocked env vars (explicit injection wins)", () => {
      process.env.OPENAI_API_KEY = "old-leaked-value";
      const env = buildSubprocessEnv({ OPENAI_API_KEY: "explicitly-injected" });
      // The process.env version is blocked, but extra injects it explicitly
      expect(env.OPENAI_API_KEY).toBe("explicitly-injected");
    });

    it("extra does not pollute when undefined", () => {
      process.env.HOME = "/home/test";
      const env = buildSubprocessEnv(undefined);
      expect(env.HOME).toBe("/home/test");
      expect(Object.keys(env).length).toBeGreaterThan(0);
    });

    it("extra with empty object is a no-op", () => {
      process.env.HOME = "/home/test";
      const withExtra = buildSubprocessEnv({});
      const without = buildSubprocessEnv();
      expect(withExtra).toEqual(without);
    });
  });

  // ── P0: Undefined value handling ──────────────────────────────

  describe("skips undefined values", () => {
    it("does not include env vars with undefined values", () => {
      // In Node, process.env can have undefined values after delete
      process.env.HOME = "/home/test";
      const env = buildSubprocessEnv();
      for (const value of Object.values(env)) {
        expect(value).not.toBeUndefined();
      }
    });
  });

  // ── P0: No full process.env passthrough ───────────────────────

  describe("never returns full process.env", () => {
    it("output is strictly smaller than process.env when credentials present", () => {
      // Load both allowed and blocked vars
      process.env.HOME = "/home/test";
      process.env.PATH = "/usr/bin";
      process.env.NVIDIA_API_KEY = FAKE_NVIDIA_KEY;
      process.env.GITHUB_TOKEN = FAKE_GITHUB_TOKEN;
      process.env.AWS_ACCESS_KEY_ID = FAKE_AWS_ACCESS;
      process.env.RANDOM_INTERNAL_VAR = "should-be-blocked";

      const env = buildSubprocessEnv();
      expect(Object.keys(env).length).toBeLessThan(Object.keys(process.env).length);
    });

    it("output does not contain any key not in allowlist or prefixes", () => {
      const NAMES = new Set([
        "HOME", "USER", "LOGNAME", "SHELL", "PATH", "TERM", "HOSTNAME", "NODE_ENV",
        "TMPDIR", "TMP", "TEMP", "LANG",
        "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy",
        "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS",
        "DOCKER_HOST", "KUBECONFIG", "SSH_AUTH_SOCK", "RUST_LOG", "RUST_BACKTRACE",
      ]);
      const PREFIXES = ["LC_", "XDG_", "OPENSHELL_", "GRPC_"];

      // Populate env with a mix
      process.env.HOME = "/home/test";
      process.env.NVIDIA_API_KEY = FAKE_NVIDIA_KEY;
      process.env.MY_CUSTOM_VAR = "blocked";
      process.env.LC_ALL = "en_US.UTF-8";

      const env = buildSubprocessEnv();
      for (const key of Object.keys(env)) {
        const allowed = NAMES.has(key) || PREFIXES.some((p) => key.startsWith(p));
        expect(allowed, `unexpected key in subprocess env: ${key}`).toBe(true);
      }
    });
  });

  // ── CLI mirror sync check ─────────────────────────────────────

  describe("CLI and plugin copies are functionally in sync", () => {
    it("src/lib/subprocess-env.ts and nemoclaw/src/lib/subprocess-env.ts have identical logic", () => {
      const fs = require("node:fs");
      const path = require("node:path");
      const root = path.resolve(import.meta.dirname, "..", "..", "..");
      // Strip the NOTE comment — each file points to its mirror, so the comment intentionally differs
      const stripNote = (s: string) => s.replace(/ \* NOTE:.*Keep them in sync\.\n/s, "");
      const cli = stripNote(fs.readFileSync(path.join(root, "src", "lib", "subprocess-env.ts"), "utf-8"));
      const plugin = stripNote(fs.readFileSync(path.join(root, "nemoclaw", "src", "lib", "subprocess-env.ts"), "utf-8"));
      expect(cli).toBe(plugin);
    });
  });
});
