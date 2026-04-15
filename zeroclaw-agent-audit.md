# ZeroClaw Agent Integration Audit

**Date:** 2026-04-15  
**Scope:** `agents/zeroclaw/` — Dockerfile, Dockerfile.base, start.sh, generate-config.ts, manifest.yaml, plugin/, policy-additions.yaml  
**Test pass rate at time of audit:** 1595/1607 (99.25%)

---

## 1. Security

### Hardening gaps

- **Capability drop is best-effort with no abort path.** `start.sh:35-46` — `capsh` drop is conditional on `CAP_SETPCAP` being available and `capsh` existing. If either check fails, the script logs a warning and continues at full capability. A container runtime that strips `CAP_SETPCAP` silently runs with the default Docker capability set.

- **`chattr +i` immutability never actually applies on overlay filesystems.** `start.sh:166` — `harden_zeroclaw_symlinks()` attempts `chattr +i` on `.zeroclaw` and its symlinks. This always fails on overlayfs (the Docker default) and continues with a warning. The function's hardening loop reports `$failed` paths "could not be hardened" but proceeds anyway. In practice this defense layer is dead on every standard container deployment.

- **`nc` is removed at build time but referenced as a proxy detection fallback.** `Dockerfile:29` removes `netcat-openbsd`, `netcat-traditional`, and `ncat`. `start.sh:229` then falls back to `nc -z -w 2` if `curl` fails. The `nc` branch is permanently dead — it will always exit non-zero — making the fallback misleading and untestable.

- **`ZEROCLAW_API_KEY` is never validated before gateway launch.** `manifest.yaml:69` declares `web_auth_method: bearer_token` / `web_auth_env: ZEROCLAW_API_KEY` but `start.sh` never checks whether this env var is set. A deployment that omits the API key starts an unauthenticated gateway with no warning.

- **Config integrity check covers only `config.toml`, not the WASM plugin.** The `sha256sum` hash baked at build time (Dockerfile:97-100) pins `config.toml` only. `nemoclaw.wasm` and `manifest.toml` in the plugin directory have no build-time hash. A tampered WASM payload would pass the startup integrity check.

- **ZeroClaw Labs policy allows unbounded POST `/**`.** `policy-additions.yaml:125-127` — both `zeroclaw-labs.com` and `api.zeroclaw-labs.com` allow `POST /**`. The existing test in `validate-blueprint.test.ts` checks for `method: "*"` wildcards but not `path: "/**"`. Any POST endpoint on those domains is reachable from within the sandbox.

- **`NEMOCLAW_PROVIDER_KEY` is dead code in config generation.** `generate-config.ts:66-67` — `providerKey` is assigned from `process.env.NEMOCLAW_PROVIDER_KEY` but is never read again. Provider resolution uses `KNOWN_PROVIDERS[baseUrl]` exclusively. The ARG is passed through the Dockerfile ENV block, builds correctly, and silently has no effect.

- **`NEMOCLAW_BUILD_ID` ARG is declared but never promoted to ENV.** `Dockerfile:55` declares the ARG; the ENV block on lines 58-62 omits it. It is also not referenced in any subsequent `RUN` layer. It cannot be read at runtime or used for image labeling as presumably intended.

---

## 2. Reliability

### Single points of failure

- **No `HEALTHCHECK` instruction in either Dockerfile.** The manifest's `health_probe` is consumed by NemoClaw/OpenShell but Docker-native health reporting is absent. Running outside OpenShell (standalone `docker run`, Brev dry-run, CI) reports no health status and `docker ps` always shows healthy.

- **Gateway crash exits the container with no restart.** `start.sh:365` — `wait "$GATEWAY_PID"` propagates the exit code but there is no supervisor loop. A gateway crash terminates the container. There is no retry, no backoff, no supervisord/s6. Combined with no `HEALTHCHECK`, a short-lived crash-loop would not be caught by the orchestrator.

- **Gateway log at `/tmp/gateway.log` has no rotation or size cap.** All gateway stdout/stderr funnels to this single file via `nohup`. Long-running deployments can fill `/tmp` and cause `nohup` to stall or the gateway to crash when it can no longer write logs.

- **Plugin load success is not verified at startup.** `start.sh` confirms config integrity and launches the gateway, but never checks whether ZeroClaw actually loaded the WASM plugin. A plugin ABI mismatch or missing export would result in the gateway reporting healthy while the `nemoclaw_status` / `nemoclaw_info` tools are silently broken.

- **`health_probe.timeout_seconds: 60` is unusually long.** A 60-second window before the orchestrator flags a dead gateway means a crashed process goes undetected for up to a minute. For an autonomous agent gateway this is a significant detection lag.

- **Proxy detection race: curl probes the proxy at startup only.** If the OpenShell L7 proxy becomes unavailable after startup, all outbound traffic silently fails — there is no mid-session fallback or re-probe path.

---

## 3. Test Gaps

### Critical: ZeroClaw entrypoint has zero test coverage

- **`nemoclaw-start.test.ts` targets the wrong file.** Line 9 reads `scripts/nemoclaw-start.sh` (the generic OpenClaw/Hermes entrypoint), not `agents/zeroclaw/start.sh`. Every assertion in that file — `AUTO_PAIR_PID`, `OPENCLAW_GATEWAY_TOKEN`, `print_dashboard_urls`, `apply_model_override` with `openclaw.json`, `start_auto_pair`, auto-pair whitelisting — is about features that exist in the OpenClaw script and **do not exist** in the ZeroClaw `start.sh`. There are zero passing tests that exercise any behavior in `agents/zeroclaw/start.sh`.

- **`generate-config.ts` is completely untested.** No test validates:
  - Correct TOML output structure
  - Base64 decode failures for `NEMOCLAW_MESSAGING_CHANNELS_B64` (invalid base64 throws synchronously)
  - The `NEMOCLAW_PROVIDER_KEY` dead-code bug (assigned but ignored)
  - Handling of an undefined `NEMOCLAW_MODEL` (TypeScript `!` assertion is stripped at runtime by `--experimental-strip-types`)
  - Provider URL → native provider name mapping

- **`security-c2-dockerfile-injection.test.ts` targets the root `Dockerfile`, not `agents/zeroclaw/Dockerfile`.** ZeroClaw's Dockerfile has no equivalent injection regression guard. A future refactor that moves config generation inline into a `RUN` layer would be unchecked.

- **No test for config integrity verification.** `verify_config_integrity()` is never exercised. Nothing tests: startup refusal on tampered config, startup refusal on missing `.config-hash`, or behavior when `sha256sum -c` is unavailable.

- **No test for symlink validation.** `validate_zeroclaw_symlinks()` has no coverage. A symlink pointing outside `.zeroclaw-data` would not be caught by any test.

- **No test for WASM plugin path or hash.** The build copies `nemoclaw.wasm` to a well-known path but no test validates the binary exists at that path in the built image or matches an expected sha256.

### Stub/production config divergence is undetected

- **Stub Dockerfile generates structurally different TOML than the real config generator.** `Dockerfile.stub` (Python generator, lines 134-175) emits `workspace_dir`, `config_path`, and a `[provider.compatible]` section with `api_key = "openshell:resolve:env:NVIDIA_API_KEY"`. The real `generate-config.ts` generates none of these. All local testing runs against the stub config schema. No test validates that the stub and real generators produce equivalent output for the same inputs.

---

## 4. Upstream Compatibility

### Manifest / binary contract

- **`version_constraint: ">=0.6.0"` has no ceiling.** A semver-breaking v0.7.0 or v1.0.0 would be silently accepted. The binary is pinned to v0.6.9 in `Dockerfile.base:28` but the manifest communicates no upper bound to the orchestrator. No test validates that the declared constraint matches the pinned version.

- **`inference.base_url_config_key: "provider.compatible.base_url"` is wrong for non-custom endpoints.** `manifest.yaml:87` says the base URL lives at `provider.compatible.base_url` in TOML. The real `generate-config.ts` never writes a `[provider.compatible]` section for known providers (Together, OpenAI, Groq, etc.) — for those, `default_provider` is set to the native name and the URL is implicit. The manifest's declared key only matches the fallback `custom:<url>` path. Any NemoClaw tooling that introspects provider config via the manifest key will get incorrect results for native-provider deployments.

- **`gateway_command` in manifest vs actual launch command.** `manifest.yaml:19` declares `gateway_command: "zeroclaw gateway start"`. `start.sh` actually runs `gosu gateway "$ZEROCLAW" gateway start --config-dir "${ZEROCLAW_WRITABLE}"`. The `--config-dir` flag is load-bearing — without it ZeroClaw uses its own user-home detection instead of the writable directory. If the manifest command is ever used by NemoClaw to restart the gateway directly (e.g., in a recovery flow), the gateway would start with a missing or wrong config.

- **TOML config schema is not validated against ZeroClaw's actual accepted keys.** Fields like `allow_public_bind`, `require_pairing`, `plugins_dir`, and the channel block structure are ZeroClaw-specific. If upstream renames any of these (e.g., `require_pairing` → `pairing_required`), the config silently falls back to defaults. No schema file or validation step exists to catch this at build time.

- **Plugin `permissions: ["env_read", "file_read"]` may silently expand in future ZeroClaw versions.** `plugin/manifest.toml:15` — permissions are advisory. If ZeroClaw changes to enforce a capability model or adds new permission flags, the plugin may fail to load without a manifest update. No test validates the plugin loads against the pinned binary version.

- **`health_probe.url` uses `localhost` but gateway binds to `[::]`.** Minor but worth noting: the probe uses `http://localhost:42617/health` while the gateway is configured with `host = "[::]"`. On systems where `localhost` does not resolve to `::1`, IPv4 (`127.0.0.1`) and IPv6 (`::1`) can behave differently. This is not a current breakage but could surface if ZeroClaw changes its binding behavior.

---

## Summary Priority Table

| Finding | Category | Severity |
|---|---|---|
| `agents/zeroclaw/start.sh` has zero test coverage | Test gap | High |
| `generate-config.ts` has zero test coverage | Test gap | High |
| `ZEROCLAW_API_KEY` never checked → silent unauthenticated gateway | Security | High |
| `inference.base_url_config_key` in manifest wrong for native providers | Upstream compat | High |
| Config integrity doesn't cover WASM plugin | Security | Medium |
| Stub and real config generator produce different schemas | Test gap | Medium |
| No `HEALTHCHECK` in Dockerfile | Reliability | Medium |
| Gateway crash exits container, no restart | Reliability | Medium |
| `NEMOCLAW_PROVIDER_KEY` is dead code | Security / Correctness | Medium |
| `nc` fallback in proxy detection is dead code | Reliability | Low |
| ZeroClaw Labs policy allows POST `/**` | Security | Low |
| `chattr +i` never applies on overlayfs | Security | Low |
| `gateway_command` in manifest missing `--config-dir` | Upstream compat | Low |
| `version_constraint` has no ceiling | Upstream compat | Low |
| `/tmp/gateway.log` has no rotation | Reliability | Low |
