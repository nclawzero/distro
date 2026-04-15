// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-FileCopyrightText: Copyright (c) 2026 Jason Perlow. All rights reserved.
// SPDX-License-Identifier: Apache-2.0
//
// NemoClaw WASM plugin for ZeroClaw.
//
// Provides sandbox status tools when ZeroClaw runs inside an OpenShell
// sandbox managed by NemoClaw. Compiled to wasm32-wasip1 via the Extism
// Plugin Development Kit (PDK).
//
// Exposed functions:
//   nemoclaw_status  — human-readable sandbox status string
//   nemoclaw_info    — structured JSON sandbox info

use extism_pdk::*;
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize)]
struct SandboxInfo {
    agent: String,
    model: String,
    provider: String,
    base_url: String,
    gateway: String,
    port: u16,
}

/// Parse a minimal subset of TOML to extract a string value by key.
/// Handles `key = "value"` and `key = 'value'` on the same line.
fn toml_get(content: &str, key: &str) -> Option<String> {
    for line in content.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix(key) {
            let rest = rest.trim_start();
            if let Some(rest) = rest.strip_prefix('=') {
                let val = rest.trim();
                // Strip surrounding quotes
                for quote in ['"', '\''] {
                    if val.starts_with(quote) && val.ends_with(quote) && val.len() >= 2 {
                        return Some(val[1..val.len() - 1].to_string());
                    }
                }
            }
        }
    }
    None
}

fn gather_info() -> SandboxInfo {
    // Try to read config.toml from writable home dir first, then immutable dir.
    let config_paths = [
        "/sandbox/.zeroclaw-data/config.toml",
        "/sandbox/.zeroclaw/config.toml",
    ];

    let mut model = String::from("unknown");
    let mut provider = String::from("compatible");
    let mut base_url = String::from("unknown");

    for path in &config_paths {
        if let Ok(content) = std::fs::read_to_string(path) {
            if let Some(m) = toml_get(&content, "default_model") {
                model = m;
            }
            if let Some(m) = toml_get(&content, "default_provider") {
                provider = m;
            }
            if let Some(u) = toml_get(&content, "base_url") {
                base_url = u;
            }
            break;
        }
    }

    // Check gateway liveness by attempting to connect to /health.
    // Use the zeroclaw CLI if available; fall back to a TCP check.
    let gateway = check_gateway_health();

    SandboxInfo {
        agent: "zeroclaw".to_string(),
        model,
        provider,
        base_url,
        gateway,
        port: 42617,
    }
}

fn check_gateway_health() -> String {
    // Use zeroclaw status --format=exit-code if the binary is accessible.
    if let Ok(output) = std::process::Command::new("zeroclaw")
        .args(["status", "--format=exit-code"])
        .output()
    {
        if output.status.success() {
            return "running".to_string();
        }
    }
    // Fallback: try TCP connect to gateway port.
    use std::net::TcpStream;
    use std::time::Duration;
    match TcpStream::connect_timeout(
        &"127.0.0.1:42617".parse().unwrap(),
        Duration::from_secs(2),
    ) {
        Ok(_) => "running".to_string(),
        Err(_) => "stopped".to_string(),
    }
}

/// nemoclaw_status — returns a human-readable sandbox status string.
#[plugin_fn]
pub fn nemoclaw_status(_input: String) -> FnResult<String> {
    let info = gather_info();
    let divider = "─".repeat(40);
    let output = format!(
        "NemoClaw Sandbox Status (ZeroClaw)\n\
         {divider}\n\
           Agent:    ZeroClaw\n\
           Gateway:  {gateway}\n\
           Model:    {model}\n\
           Provider: {provider}\n\
           Endpoint: {base_url}\n\
           API:      http://localhost:{port}/v1",
        gateway = info.gateway,
        model = info.model,
        provider = info.provider,
        base_url = info.base_url,
        port = info.port,
    );
    Ok(output)
}

/// nemoclaw_info — returns structured JSON sandbox info.
#[plugin_fn]
pub fn nemoclaw_info(_input: String) -> FnResult<String> {
    let info = gather_info();
    Ok(serde_json::to_string_pretty(&info)?)
}
