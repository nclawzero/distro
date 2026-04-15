// @ts-nocheck
// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-FileCopyrightText: Copyright (c) 2026 Jason Perlow. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

import fs from "node:fs";
import path from "node:path";
import { describe, it, expect } from "vitest";

const START_SCRIPT = path.join(
  import.meta.dirname,
  "..",
  "agents",
  "zeroclaw",
  "start.sh",
);

describe("zeroclaw start.sh config integrity", () => {
  const src = fs.readFileSync(START_SCRIPT, "utf-8");

  it("defines verify_config_integrity() function with sha256 check", () => {
    expect(src).toMatch(/verify_config_integrity\(\) \{/);
    // Must use sha256sum to verify config hash
    expect(src).toContain("sha256sum -c");
    expect(src).toContain(".config-hash");
  });

  it("calls verify_config_integrity in both root and non-root paths", () => {
    // The function must be called at least twice: once in the non-root
    // if-block and once in the root path below it, plus the definition.
    const calls = src.match(/verify_config_integrity/g) || [];
    expect(calls.length).toBeGreaterThanOrEqual(3); // definition + 2 call sites
  });

  it("exits non-zero on config verification failure in non-root mode", () => {
    // Non-root block must call verify_config_integrity and exit 1 on failure
    expect(src).toMatch(/if ! verify_config_integrity; then\s+.*exit 1/s);
  });

  it("verify_config_integrity returns 1 when hash file is missing", () => {
    const fn = src.match(/verify_config_integrity\(\) \{([\s\S]*?)^}/m);
    expect(fn).toBeTruthy();
    expect(fn[1]).toContain("Config hash file missing");
    expect(fn[1]).toContain("return 1");
  });

  it("verify_config_integrity returns 1 when integrity check fails", () => {
    const fn = src.match(/verify_config_integrity\(\) \{([\s\S]*?)^}/m);
    expect(fn).toBeTruthy();
    expect(fn[1]).toContain("config may have been tampered with");
    expect(fn[1]).toContain("return 1");
  });
});

describe("zeroclaw start.sh gateway launch", () => {
  const src = fs.readFileSync(START_SCRIPT, "utf-8");

  it("launches zeroclaw with 'gateway start' command", () => {
    // The script must launch zeroclaw gateway start (not 'gateway run' like OpenClaw)
    expect(src).toContain('zeroclaw gateway start');
    expect(src).toMatch(
      /\$ZEROCLAW" gateway start --config-dir "\$\{ZEROCLAW_WRITABLE\}"/,
    );
  });

  it("resolves the zeroclaw binary path once via command -v", () => {
    expect(src).toMatch(/ZEROCLAW="\$\(command -v zeroclaw\)"/);
  });

  it("uses nohup to detach gateway from entrypoint", () => {
    expect(src).toMatch(/nohup.*\$ZEROCLAW.*gateway start/);
  });

  it("redirects gateway output to log file", () => {
    expect(src).toMatch(/nohup.*>\/tmp\/gateway\.log 2>&1 &/);
  });

  it("captures GATEWAY_PID from background process", () => {
    expect(src).toContain("GATEWAY_PID=$!");
  });

  it("waits on GATEWAY_PID to keep container alive", () => {
    expect(src).toMatch(/wait "\$GATEWAY_PID"/);
  });

  it("sets GATEWAY_PORT to 42617", () => {
    expect(src).toContain("GATEWAY_PORT=42617");
  });
});

describe("zeroclaw start.sh gosu privilege separation", () => {
  const src = fs.readFileSync(START_SCRIPT, "utf-8");

  it("uses gosu for user switching in root path", () => {
    // Root path launches gateway as 'gateway' user via gosu
    expect(src).toMatch(/gosu gateway "\$ZEROCLAW" gateway start/);
  });

  it("uses gosu for NEMOCLAW_CMD execution in root path", () => {
    expect(src).toMatch(/exec gosu sandbox "\$\{NEMOCLAW_CMD\[@\]\}"/);
  });

  it("skips gosu in non-root fallback path", () => {
    // Non-root block should NOT use gosu
    const nonRootBlock = src.match(
      /if \[ "\$\(id -u\)" -ne 0 \]; then([\s\S]*?)# ── Root path/,
    );
    expect(nonRootBlock).toBeTruthy();
    expect(nonRootBlock[1]).not.toContain("gosu");
  });

  it("logs privilege separation disabled message when non-root", () => {
    expect(src).toContain("privilege separation disabled");
  });

  it("changes ownership of writable dir to gateway:sandbox in root path", () => {
    expect(src).toContain('chown -R gateway:sandbox "${ZEROCLAW_WRITABLE}"');
  });
});

describe("zeroclaw start.sh proxy detection", () => {
  const src = fs.readFileSync(START_SCRIPT, "utf-8");

  it("checks for proxy reachability before setting HTTPS_PROXY", () => {
    // Must test connectivity before exporting proxy vars
    expect(src).toMatch(
      /if curl.*\|\| nc.*then[\s\S]*?export HTTPS_PROXY/s,
    );
  });

  it("defines PROXY_HOST and PROXY_PORT with defaults", () => {
    expect(src).toContain('PROXY_HOST="${NEMOCLAW_PROXY_HOST:-10.200.0.1}"');
    expect(src).toContain('PROXY_PORT="${NEMOCLAW_PROXY_PORT:-3128}"');
  });

  it("sets both upper and lower case proxy env vars", () => {
    expect(src).toContain('export HTTP_PROXY="$_PROXY_URL"');
    expect(src).toContain('export HTTPS_PROXY="$_PROXY_URL"');
    expect(src).toContain('export http_proxy="$_PROXY_URL"');
    expect(src).toContain('export https_proxy="$_PROXY_URL"');
  });

  it("sets NO_PROXY for localhost and proxy host", () => {
    expect(src).toContain('export NO_PROXY="$_NO_PROXY_VAL"');
    expect(src).toContain('export no_proxy="$_NO_PROXY_VAL"');
  });

  it("logs when proxy is detected", () => {
    expect(src).toContain("[proxy] OpenShell proxy detected");
  });

  it("logs when proxy is not available", () => {
    expect(src).toContain("[proxy] No proxy at");
  });

  it("uses idempotent marker blocks for proxy config in rc files", () => {
    expect(src).toContain("nemoclaw-proxy-config begin");
    expect(src).toContain("nemoclaw-proxy-config end");
  });
});

describe("zeroclaw start.sh health probe URL", () => {
  const src = fs.readFileSync(START_SCRIPT, "utf-8");

  it("references port 42617 for the gateway", () => {
    expect(src).toContain("42617");
  });

  it("prints health URL pointing to port 42617", () => {
    // print_gateway_urls should include the health endpoint
    const urlFn = src.match(/print_gateway_urls\(\) \{([\s\S]*?)^}/m);
    expect(urlFn).toBeTruthy();
    expect(urlFn[1]).toContain("/health");
    expect(urlFn[1]).toContain("GATEWAY_PORT");
  });

  it("prints the /v1 API endpoint", () => {
    const urlFn = src.match(/print_gateway_urls\(\) \{([\s\S]*?)^}/m);
    expect(urlFn).toBeTruthy();
    expect(urlFn[1]).toContain("/v1");
  });
});

describe("zeroclaw start.sh error handling", () => {
  const src = fs.readFileSync(START_SCRIPT, "utf-8");

  it("uses set -euo pipefail for strict error handling", () => {
    expect(src).toContain("set -euo pipefail");
  });

  it("exits non-zero on config verification failure in non-root mode", () => {
    const nonRootBlock = src.match(
      /if \[ "\$\(id -u\)" -ne 0 \]; then([\s\S]*?)# ── Root path/,
    );
    expect(nonRootBlock).toBeTruthy();
    expect(nonRootBlock[1]).toContain("exit 1");
  });

  it("defines cleanup() for signal handling", () => {
    expect(src).toMatch(/^cleanup\(\)/m);
  });

  it("traps SIGTERM and SIGINT for graceful shutdown", () => {
    expect(src).toContain("trap cleanup SIGTERM SIGINT");
  });

  it("cleanup forwards SIGTERM to GATEWAY_PID", () => {
    const cleanup = src.match(/cleanup\(\) \{([\s\S]*?)^}/m);
    expect(cleanup).toBeTruthy();
    expect(cleanup[1]).toContain('kill -TERM "$GATEWAY_PID"');
  });

  it("cleanup exits with gateway exit status", () => {
    const cleanup = src.match(/cleanup\(\) \{([\s\S]*?)^}/m);
    expect(cleanup).toBeTruthy();
    expect(cleanup[1]).toContain('exit "$gateway_status"');
  });
});

describe("zeroclaw start.sh no env var leaks", () => {
  const src = fs.readFileSync(START_SCRIPT, "utf-8");

  it("does not echo or log API key values", () => {
    // Ensure no echo/printf of API key env vars
    const lines = src.split("\n");
    for (const line of lines) {
      const trimmed = line.trim();
      // Skip comments
      if (trimmed.startsWith("#")) continue;
      // Lines that echo should not contain API key variable expansions
      if (
        trimmed.match(
          /echo.*\$\{?(NVIDIA_API_KEY|OPENAI_API_KEY|ANTHROPIC_API_KEY|API_KEY)\}?/,
        )
      ) {
        // This should not match in the script
        expect(trimmed).not.toMatch(
          /echo.*\$\{?(NVIDIA_API_KEY|OPENAI_API_KEY|ANTHROPIC_API_KEY)\}?/,
        );
      }
    }
  });

  it("does not log bot token values in messaging channel detection", () => {
    // The channel detection must NOT expand token values into log output
    const channelFn = src.match(
      /configure_messaging_channels\(\) \{([\s\S]*?)^}/m,
    );
    expect(channelFn).toBeTruthy();
    const body = channelFn[1];
    // Should log channel names, not token values
    expect(body).toContain('"[channels]   telegram"');
    expect(body).not.toMatch(
      /echo.*\$\{?TELEGRAM_BOT_TOKEN\}?[^:=-]/,
    );
  });

  it("sends startup diagnostics to stderr", () => {
    expect(src).toContain("echo 'Setting up NemoClaw (ZeroClaw)...' >&2");
  });

  it("all print_gateway_urls echoes go to stderr", () => {
    const urlFn = src.match(/print_gateway_urls\(\) \{([\s\S]*?)^}/m);
    expect(urlFn).toBeTruthy();
    const echoLines = urlFn[1].match(/^\s*echo\s+.+$/gm) || [];
    expect(echoLines.length).toBeGreaterThan(0);
    for (const line of echoLines) {
      expect(line).toContain(">&2");
    }
  });

  it("protects gateway log with chmod 600", () => {
    expect(src).toContain("chmod 600 /tmp/gateway.log");
  });
});

describe("zeroclaw start.sh validate_zeroclaw_symlinks", () => {
  const src = fs.readFileSync(START_SCRIPT, "utf-8");

  it("defines validate_zeroclaw_symlinks function", () => {
    expect(src).toMatch(/validate_zeroclaw_symlinks\(\) \{/);
  });

  it("checks symlinks point to expected .zeroclaw-data targets", () => {
    const fn = src.match(/validate_zeroclaw_symlinks\(\) \{([\s\S]*?)^}/m);
    expect(fn).toBeTruthy();
    expect(fn[1]).toContain("/sandbox/.zeroclaw-data/$name");
    expect(fn[1]).toContain("readlink");
  });

  it("returns 1 on unexpected symlink target", () => {
    const fn = src.match(/validate_zeroclaw_symlinks\(\) \{([\s\S]*?)^}/m);
    expect(fn).toBeTruthy();
    expect(fn[1]).toContain("Symlink $entry points to unexpected target");
    expect(fn[1]).toContain("return 1");
  });

  it("calls validate_zeroclaw_symlinks in root path before harden", () => {
    const rootBlock = src.split(/# ── Root path/)[1] || "";
    const validateIdx = rootBlock.indexOf("validate_zeroclaw_symlinks");
    const hardenIdx = rootBlock.indexOf("harden_zeroclaw_symlinks");
    expect(validateIdx).toBeGreaterThan(-1);
    expect(hardenIdx).toBeGreaterThan(-1);
    expect(validateIdx).toBeLessThan(hardenIdx);
  });
});

describe("zeroclaw start.sh log file setup", () => {
  const src = fs.readFileSync(START_SCRIPT, "utf-8");

  it("creates /tmp/gateway.log in non-root path", () => {
    const nonRootBlock = src.match(
      /if \[ "\$\(id -u\)" -ne 0 \]; then([\s\S]*?)# ── Root path/,
    );
    expect(nonRootBlock).toBeTruthy();
    expect(nonRootBlock[1]).toContain("touch /tmp/gateway.log");
    expect(nonRootBlock[1]).toContain("chmod 600 /tmp/gateway.log");
  });

  it("creates /tmp/gateway.log in root path", () => {
    const rootBlock = src.split(/# ── Root path/)[1] || "";
    expect(rootBlock).toContain("touch /tmp/gateway.log");
    expect(rootBlock).toContain("chmod 600 /tmp/gateway.log");
  });

  it("redirects gateway output to /tmp/gateway.log", () => {
    // Both root and non-root paths redirect to /tmp/gateway.log
    const matches = src.match(/>\/tmp\/gateway\.log 2>&1 &/g) || [];
    expect(matches.length).toBeGreaterThanOrEqual(2);
  });
});

describe("zeroclaw start.sh security hardening", () => {
  const src = fs.readFileSync(START_SCRIPT, "utf-8");

  it("locks down PATH", () => {
    expect(src).toContain(
      'export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"',
    );
  });

  it("drops unnecessary Linux capabilities via capsh", () => {
    expect(src).toContain("capsh");
    expect(src).toContain("cap_net_raw");
    expect(src).toContain("cap_dac_override");
  });

  it("sets nproc ulimit to prevent fork bombs", () => {
    expect(src).toContain("ulimit -Su 512");
    expect(src).toContain("ulimit -Hu 512");
  });

  it("defines harden_zeroclaw_symlinks function using chattr +i", () => {
    const fn = src.match(/harden_zeroclaw_symlinks\(\) \{([\s\S]*?)^}/m);
    expect(fn).toBeTruthy();
    expect(fn[1]).toContain("chattr +i");
  });

  it("installs configure guard to prevent config modification from sandbox", () => {
    expect(src).toMatch(/install_configure_guard\(\) \{/);
    const fn = src.match(/install_configure_guard\(\) \{([\s\S]*?)^}/m);
    expect(fn).toBeTruthy();
    expect(fn[1]).toContain("cannot modify config inside the sandbox");
  });

  it("deploys config with restricted permissions (chmod 600)", () => {
    const fn = src.match(/deploy_config_to_writable\(\) \{([\s\S]*?)^}/m);
    expect(fn).toBeTruthy();
    expect(fn[1]).toContain('chmod 600 "${ZEROCLAW_WRITABLE}/config.toml"');
  });
});

describe("zeroclaw start.sh self-wrapper bootstrap", () => {
  const src = fs.readFileSync(START_SCRIPT, "utf-8");

  it("unwraps the sandbox-create env self-wrapper before building NEMOCLAW_CMD", () => {
    expect(src).toContain('if [ "${1:-}" = "env" ]; then');
    expect(src).toContain('export "${_raw_args[$i]}"');
    expect(src).toContain(
      'set -- "${_raw_args[@]:$((_self_wrapper_index + 1))}"',
    );
  });

  it("strips self-referencing nemoclaw-start from argv", () => {
    expect(src).toMatch(
      /nemoclaw-start \| \/usr\/local\/bin\/nemoclaw-start\)/,
    );
    expect(src).toContain('NEMOCLAW_CMD=("$@")');
  });
});
