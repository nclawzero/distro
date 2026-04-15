// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-FileCopyrightText: Copyright (c) 2026 Jason Perlow. All rights reserved.
// SPDX-License-Identifier: Apache-2.0
//
// Security tests for the ZeroClaw agent integration (agents/zeroclaw/).
//
// Validates: Dockerfile injection prevention, manifest path traversal guards,
// config integrity verification, capability drops, privilege separation,
// network policy wildcards, secret hygiene, and WASM plugin safety.

// @ts-nocheck
import { describe, it, expect } from "vitest";
import fs from "node:fs";
import path from "node:path";

const ZEROCLAW_DIR = path.join(import.meta.dirname, "..", "agents", "zeroclaw");

// All files in agents/zeroclaw/ for bulk scanning
const ALL_ZEROCLAW_FILES: string[] = [];
function collectFiles(dir: string): void {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      collectFiles(full);
    } else {
      ALL_ZEROCLAW_FILES.push(full);
    }
  }
}
collectFiles(ZEROCLAW_DIR);

// ═══════════════════════════════════════════════════════════════════
// 1. Dockerfile injection prevention
// ═══════════════════════════════════════════════════════════════════
describe("Dockerfile injection prevention", () => {
  const dockerfiles = [
    "Dockerfile",
    "Dockerfile.base",
    "Dockerfile.stub",
    "Dockerfile.stub.base",
  ];

  for (const name of dockerfiles) {
    const filepath = path.join(ZEROCLAW_DIR, name);
    if (!fs.existsSync(filepath)) continue;

    describe(name, () => {
      it("does not interpolate ${VAR} inside unquoted RUN shell commands", () => {
        const src = fs.readFileSync(filepath, "utf-8");
        const lines = src.split("\n");
        const violations: { line: number; content: string }[] = [];

        let inRunBlock = false;
        for (let i = 0; i < lines.length; i++) {
          const line = lines[i];
          // Detect start of a RUN instruction
          if (/^\s*RUN\b/.test(line)) {
            inRunBlock = true;
          }
          if (inRunBlock) {
            // Look for ${VAR} patterns that are NOT inside double quotes
            // and NOT in an ENV or ARG instruction context.
            // Safe patterns: "${VAR}", $(...), or ENV/ARG lines.
            // Unsafe: bare ${VAR} in shell commands without quotes around them.
            //
            // We specifically check for ${NEMOCLAW_*} or ${CHAT_UI_URL} in
            // RUN blocks that contain shell execution (not ENV promotion).
            const buildArgRefs = line.match(/\$\{(NEMOCLAW_\w+|CHAT_UI_URL)\}/g) || [];
            for (const ref of buildArgRefs) {
              // Check if this ref appears inside a python3 -c inline script
              // (which would be code injection). The safe pattern is to use
              // a separate script file or os.environ reads.
              if (/python3\s+-c/.test(line) || /python3\s+-c/.test(lines[i - 1] || "")) {
                violations.push({ line: i + 1, content: line.trim() });
              }
            }
          }
          // RUN block ends when line does not end with backslash
          if (inRunBlock && !/\\\s*$/.test(line)) {
            inRunBlock = false;
          }
        }

        expect(violations).toEqual([]);
      });

      it("promotes build-args to ENV vars before RUN layers that use them", () => {
        const src = fs.readFileSync(filepath, "utf-8");
        // The ZeroClaw Dockerfile uses ENV to promote build-args, then
        // calls a separate script (generate-config.ts or python3 -) that
        // reads from process.env / os.environ. This is the safe pattern.
        //
        // Check that no RUN line directly interpolates a NEMOCLAW_ build-arg
        // into inline code (as opposed to using it as a file path or copy source).
        const lines = src.split("\n");
        let inRunBlock = false;
        let inlineCodeInjection = false;

        for (let i = 0; i < lines.length; i++) {
          const line = lines[i];
          if (/^\s*RUN\b/.test(line)) inRunBlock = true;
          if (inRunBlock) {
            // Detect inline code generation that interpolates build-args
            // Pattern: python3 -c "...${NEMOCLAW_*}..." or echo "...${NEMOCLAW_*}..."
            if (
              /(?:python3\s+-c|echo\s+['"])/.test(line) &&
              /\$\{NEMOCLAW_\w+\}/.test(line)
            ) {
              inlineCodeInjection = true;
            }
          }
          if (inRunBlock && !/\\\s*$/.test(line)) inRunBlock = false;
        }

        expect(inlineCodeInjection).toBe(false);
      });
    });
  }
});

// ═══════════════════════════════════════════════════════════════════
// 2. Manifest path traversal
// ═══════════════════════════════════════════════════════════════════
describe("manifest.yaml path traversal prevention", () => {
  const manifestPath = path.join(ZEROCLAW_DIR, "manifest.yaml");
  const manifest = fs.readFileSync(manifestPath, "utf-8");

  it("contains no '..' path traversal in any field value", () => {
    const lines = manifest.split("\n");
    const violations: { line: number; content: string }[] = [];

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      // Skip comment lines
      if (/^\s*#/.test(line)) continue;
      // Check for ".." in path-like values (after a colon)
      if (/:\s*.*\.\./.test(line)) {
        violations.push({ line: i + 1, content: line.trim() });
      }
    }

    expect(violations).toEqual([]);
  });

  it("binary_path is an absolute path", () => {
    const match = manifest.match(/^binary_path:\s*(.+)$/m);
    expect(match).toBeTruthy();
    expect(match![1].trim().startsWith("/")).toBe(true);
  });

  it("config paths use absolute /sandbox/ prefix", () => {
    const immutableMatch = manifest.match(/immutable_dir:\s*(.+)/);
    const writableMatch = manifest.match(/writable_dir:\s*(.+)/);
    expect(immutableMatch).toBeTruthy();
    expect(writableMatch).toBeTruthy();
    expect(immutableMatch![1].trim().startsWith("/sandbox/")).toBe(true);
    expect(writableMatch![1].trim().startsWith("/sandbox/")).toBe(true);
  });
});

// ═══════════════════════════════════════════════════════════════════
// 3. Config integrity — start.sh sha256sum verification
// ═══════════════════════════════════════════════════════════════════
describe("config integrity verification in start.sh", () => {
  const startSh = fs.readFileSync(
    path.join(ZEROCLAW_DIR, "start.sh"),
    "utf-8",
  );

  it("defines a verify_config_integrity function", () => {
    expect(startSh).toMatch(/verify_config_integrity\s*\(\)/);
  });

  it("verify_config_integrity uses sha256sum to check config hash", () => {
    // Extract the function body
    const fnStart = startSh.indexOf("verify_config_integrity()");
    expect(fnStart).not.toBe(-1);
    const fnBody = startSh.slice(fnStart, startSh.indexOf("\n}", fnStart) + 2);
    expect(fnBody).toContain("sha256sum");
    expect(fnBody).toContain(".config-hash");
  });

  it("calls verify_config_integrity before launching the gateway (root path)", () => {
    // In the root path (after the non-root fallback block), verify_config_integrity
    // must be called before gosu gateway ... gateway start
    const rootSection = startSh.slice(startSh.indexOf("# ── Root path"));
    expect(rootSection).toBeTruthy();
    const verifyIdx = rootSection.indexOf("verify_config_integrity");
    const gatewayIdx = rootSection.indexOf("gosu gateway");
    expect(verifyIdx).not.toBe(-1);
    expect(gatewayIdx).not.toBe(-1);
    expect(verifyIdx).toBeLessThan(gatewayIdx);
  });

  it("calls verify_config_integrity before launching the gateway (non-root path)", () => {
    const nonRootSection = startSh.slice(
      startSh.indexOf("# ── Non-root fallback"),
      startSh.indexOf("# ── Root path"),
    );
    expect(nonRootSection).toBeTruthy();
    const verifyIdx = nonRootSection.indexOf("verify_config_integrity");
    const gatewayIdx = nonRootSection.indexOf("gateway start");
    expect(verifyIdx).not.toBe(-1);
    expect(gatewayIdx).not.toBe(-1);
    expect(verifyIdx).toBeLessThan(gatewayIdx);
  });

  it("refuses to start if config integrity check fails", () => {
    // After verify_config_integrity call in non-root path, there should be
    // an exit 1 on failure
    const nonRootSection = startSh.slice(
      startSh.indexOf("# ── Non-root fallback"),
      startSh.indexOf("# ── Root path"),
    );
    expect(nonRootSection).toContain("Config integrity check failed");
    expect(nonRootSection).toContain("exit 1");
  });
});

// ═══════════════════════════════════════════════════════════════════
// 4. Capability drop — capsh usage in start.sh
// ═══════════════════════════════════════════════════════════════════
describe("capability drop in start.sh", () => {
  const startSh = fs.readFileSync(
    path.join(ZEROCLAW_DIR, "start.sh"),
    "utf-8",
  );

  it("contains capsh for capability dropping", () => {
    expect(startSh).toContain("capsh");
  });

  it("drops dangerous capabilities via capsh --drop", () => {
    // capsh and --drop may be on separate lines joined by backslash continuation
    expect(startSh).toContain("capsh");
    expect(startSh).toContain("--drop=");
  });

  it("drops cap_net_raw capability", () => {
    expect(startSh).toContain("cap_net_raw");
  });

  it("drops cap_dac_override capability", () => {
    expect(startSh).toContain("cap_dac_override");
  });

  it("drops cap_sys_chroot capability", () => {
    expect(startSh).toContain("cap_sys_chroot");
  });

  it("uses NEMOCLAW_CAPS_DROPPED guard to prevent double-exec", () => {
    expect(startSh).toContain("NEMOCLAW_CAPS_DROPPED");
    // Should check and set the guard variable
    const lines = startSh.split("\n");
    const checkLine = lines.find((l) =>
      l.includes('NEMOCLAW_CAPS_DROPPED:-') && l.includes('"1"'),
    );
    expect(checkLine).toBeTruthy();
    const setLine = lines.find((l) =>
      l.includes("export NEMOCLAW_CAPS_DROPPED=1"),
    );
    expect(setLine).toBeTruthy();
  });
});

// ═══════════════════════════════════════════════════════════════════
// 5. Privilege separation — gosu usage in start.sh
// ═══════════════════════════════════════════════════════════════════
describe("privilege separation in start.sh", () => {
  const startSh = fs.readFileSync(
    path.join(ZEROCLAW_DIR, "start.sh"),
    "utf-8",
  );

  it("uses gosu for user switching", () => {
    expect(startSh).toContain("gosu");
  });

  it("launches gateway as the 'gateway' user via gosu", () => {
    expect(startSh).toMatch(/gosu\s+gateway\b/);
  });

  it("drops to 'sandbox' user for non-gateway commands via gosu", () => {
    expect(startSh).toMatch(/gosu\s+sandbox\b/);
  });

  it("sets ZEROCLAW_HOME to the writable directory", () => {
    expect(startSh).toContain('ZEROCLAW_HOME="${ZEROCLAW_WRITABLE}"');
  });
});

// ═══════════════════════════════════════════════════════════════════
// 6. Network policy wildcard validation
// ═══════════════════════════════════════════════════════════════════
describe("network policy wildcard validation", () => {
  const policyFiles = [
    "policy-additions.yaml",
    "policy-permissive.yaml",
  ];

  for (const name of policyFiles) {
    const filepath = path.join(ZEROCLAW_DIR, name);
    if (!fs.existsSync(filepath)) continue;

    describe(name, () => {
      it('does not use method: "*" wildcard', () => {
        const yaml = fs.readFileSync(filepath, "utf-8");
        const lines = yaml.split("\n");
        const violations: { line: number; content: string }[] = [];

        for (let i = 0; i < lines.length; i++) {
          const line = lines[i];
          if (/method:\s*["']\*["']/.test(line)) {
            violations.push({ line: i + 1, content: line.trim() });
          }
        }

        expect(violations).toEqual([]);
      });

      it("does not allow unrestricted method access via inline wildcards", () => {
        const yaml = fs.readFileSync(filepath, "utf-8");
        // Ensure no rules use { method: "*" } pattern
        expect(yaml).not.toMatch(/\{\s*method:\s*["']\*["']/);
      });
    });
  }
});

// ═══════════════════════════════════════════════════════════════════
// 7. No hardcoded secrets
// ═══════════════════════════════════════════════════════════════════
describe("no hardcoded secrets in agents/zeroclaw/", () => {
  // Patterns that indicate hardcoded secrets
  const SECRET_PATTERNS = [
    // API keys with actual values (not placeholder references)
    { pattern: /(?:api_key|apikey|api-key)\s*[:=]\s*["'][a-zA-Z0-9+/]{20,}["']/i, name: "API key" },
    // Bearer tokens
    { pattern: /Bearer\s+[a-zA-Z0-9._-]{20,}/i, name: "Bearer token" },
    // AWS-style keys
    { pattern: /AKIA[0-9A-Z]{16}/i, name: "AWS access key" },
    // Private keys
    { pattern: /-----BEGIN\s+(RSA\s+)?PRIVATE\s+KEY-----/, name: "Private key" },
    // Password assignments with actual values (not env var references)
    { pattern: /password\s*[:=]\s*["'][^"']{8,}["']/i, name: "Password" },
    // GitHub tokens
    { pattern: /ghp_[a-zA-Z0-9]{36}/, name: "GitHub PAT" },
    { pattern: /github_pat_[a-zA-Z0-9_]{82}/, name: "GitHub fine-grained PAT" },
    // Slack tokens
    { pattern: /xox[bpors]-[a-zA-Z0-9-]+/, name: "Slack token" },
    // Discord tokens (actual bot tokens are ~70 chars of base64)
    { pattern: /[MN][A-Za-z\d]{23,}\.[\w-]{6}\.[\w-]{27,}/, name: "Discord bot token" },
  ];

  // Files that use placeholder token references (openshell:resolve:env:*) are safe
  const SAFE_PATTERNS = [
    /openshell:resolve:env:/,
    /os\.environ/,
    /process\.env/,
    /\$\{[A-Z_]+\}/,  // Docker ARG/ENV references
  ];

  for (const filepath of ALL_ZEROCLAW_FILES) {
    const relPath = path.relative(ZEROCLAW_DIR, filepath);

    it(`${relPath} contains no hardcoded secrets`, () => {
      const content = fs.readFileSync(filepath, "utf-8");
      const violations: string[] = [];

      for (const { pattern, name } of SECRET_PATTERNS) {
        const match = content.match(pattern);
        if (match) {
          // Check if the match is on a line with a safe pattern
          const matchLine = content
            .split("\n")
            .find((l) => pattern.test(l));
          if (matchLine && !SAFE_PATTERNS.some((sp) => sp.test(matchLine))) {
            violations.push(`${name}: ${match[0].substring(0, 30)}...`);
          }
        }
      }

      expect(violations).toEqual([]);
    });
  }
});

// ═══════════════════════════════════════════════════════════════════
// 8. WASM plugin has no unsafe blocks
// ═══════════════════════════════════════════════════════════════════
describe("WASM plugin safety", () => {
  const libRsPath = path.join(ZEROCLAW_DIR, "plugin", "src", "lib.rs");
  const libRs = fs.readFileSync(libRsPath, "utf-8");

  it("plugin/src/lib.rs does not contain unsafe blocks", () => {
    // Match standalone `unsafe` keyword that starts an unsafe block,
    // but not comments or strings mentioning "unsafe"
    const lines = libRs.split("\n");
    const violations: { line: number; content: string }[] = [];

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      // Skip comment lines
      if (/^\s*\/\//.test(line)) continue;
      // Check for `unsafe {` or `unsafe fn` or `unsafe impl`
      if (/\bunsafe\s*\{/.test(line) || /\bunsafe\s+fn\b/.test(line) || /\bunsafe\s+impl\b/.test(line)) {
        violations.push({ line: i + 1, content: line.trim() });
      }
    }

    expect(violations).toEqual([]);
  });

  it("plugin/src/lib.rs does not use #[allow(unsafe_code)]", () => {
    expect(libRs).not.toMatch(/#\[allow\(unsafe_code\)\]/);
  });
});
