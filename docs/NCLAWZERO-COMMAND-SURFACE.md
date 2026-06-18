# NemoClaw → ZeroClaw Command Surface — Handoff for Harness Creation

## Overview

NemoClaw is NVIDIA's sandbox orchestration framework. ZeroClaw is a Rust AI agent runtime.
nclawzero integrates ZeroClaw as a NemoClaw agent target alongside Hermes (the default Python agent).

The integration contract is defined in `agents/zeroclaw/manifest.yaml`.

---

## ZeroClaw Process Lifecycle

### Start
```bash
zeroclaw daemon                    # Start the agent daemon
zeroclaw gateway start             # Start the gateway (NemoClaw uses this)
```

### Health Check
```
GET http://localhost:42617/health
→ {"status": "ok", "version": "0.6.9"}
```

### Configuration
- Config file: `~/.zeroclaw/config.toml` (TOML format)
- Writable data: `~/.zeroclaw-data/` (workspace, memory, logs, plugins, cache)
- Config generated at image build time by `agents/zeroclaw/generate-config.ts`

### Key Ports
| Port | Service |
|------|---------|
| 42617 | Gateway API + Web UI (OpenAI-compatible) |

---

## NemoClaw Sandbox Integration

### Directory Layout (Inside Sandbox)
```
/sandbox/.zeroclaw/              # Immutable config (Landlock read-only)
  config.toml                    # Generated TOML config
/sandbox/.zeroclaw-data/         # Writable state
  workspace/                     # Agent workspace
  memory/                        # Persistent memory
  channels_config/               # Channel configs (Telegram, Discord, Slack)
  cron/                          # Scheduled tasks
  logs/                          # Agent logs
  plugins/                       # WASM plugins
  cache/                         # Runtime cache
```

### Symlink Pattern
NemoClaw creates symlinks from the immutable config dir to the writable data dir:
```
/sandbox/.zeroclaw/workspace → /sandbox/.zeroclaw-data/workspace
/sandbox/.zeroclaw/memory → /sandbox/.zeroclaw-data/memory
(etc.)
```

### Start Script (start.sh)
Located at `agents/zeroclaw/start.sh`. Entrypoint for the sandbox container:
1. SHA256 integrity check on config.toml
2. ulimit hardening (NPROC=512)
3. PATH lockdown
4. Capability drops via capsh: cap_net_raw, cap_dac_override, cap_sys_chroot, cap_fsetid, cap_setfcap, cap_mknod, cap_audit_write, cap_net_bind_service
5. Symlink validation and immutability (chattr +i)
6. Privilege separation: gateway runs as `gateway` user, agent as `sandbox` user via gosu

---

## ZeroClaw Config Generation

`agents/zeroclaw/generate-config.ts` produces `config.toml` from build-args:

```toml
[gateway]
host = "[::]"                    # Bind all interfaces
port = 42617
allow_public_bind = true

[skills]
allow_scripts = false            # Secure default — blocks .sh/.bash files in skills
workspace_dir = "~/.zeroclaw-data/workspace"

[agent]
autonomy = "supervised"          # Requires approval for medium/high risk commands

[logging]
level = "info"
```

### Environment Variables Consumed
| Var | Purpose |
|-----|---------|
| `ANTHROPIC_API_KEY` | Default inference provider key |
| `OPENAI_API_KEY` | Alternative inference key |
| `NVIDIA_API_KEY` | NVIDIA inference key |
| `ZEROCLAW_HOME` | Override home directory |
| `ZEROCLAW_API_KEY` | Web UI bearer token auth |
| `HTTP_PROXY` / `HTTPS_PROXY` | Proxy configuration |

**CRITICAL**: ZeroClaw does NOT load .env files. All env vars must be in the process environment (systemd EnvironmentFile, or `set -a; source .env; set +a` before starting).

---

## NemoClaw CLI Commands for ZeroClaw

### Onboarding
```bash
nemoclaw onboard --agent zeroclaw    # Interactive setup wizard
```

### Sandbox Operations
```bash
openshell sandbox create <name>       # Create sandbox
openshell sandbox cp <src> <name>:<dest>  # Copy files into sandbox
openshell sandbox exec <name> -- <cmd>    # Execute command in sandbox
openshell sandbox rm <name>           # Remove sandbox
openshell status                      # Check gateway/sandbox health
```

### Recovery
```bash
nemoclaw recover --agent zeroclaw     # Rebuild sandbox from snapshot
```

---

## Skill Execution Model

### What allow_scripts gates
- **BLOCKS**: Files with extensions .sh, .bash, .zsh, .ksh, .fish, .ps1, .bat, .cmd
- **BLOCKS**: Files with shell shebangs (#!/bin/bash, #!/usr/bin/python3, etc.)
- **DOES NOT BLOCK**: Python commands in SKILL.toml tools (`command = "python3 script.py"`)
- **DOES NOT BLOCK**: Shell commands in SKILL.toml tools (`kind = "shell"`)

### Skill Tool Execution (skill_tool.rs)
```
Shell: sh -c <command>
Timeout: 60 seconds
Environment: env_clear() → only PATH, HOME, TERM, LANG, LC_ALL, USER, SHELL, TMPDIR
Validation: command allowlist, path restrictions, shell injection prevention
Approval: required for medium/high risk in supervised mode
```

### Allowed Commands (default)
```
python, python3, node, git, npm, ls, cat, head, tail, grep, find, wc, sort,
uniq, tr, cut, sed, awk, jq, curl, wget, tar, gzip, gunzip, zip, unzip,
mkdir, cp, mv, rm, touch, chmod, echo, printf, date, env, which, whoami,
hostname, uname, df, du, free, ps, top, kill, sleep, true, false, test
```

### Blocked Patterns
```
sudo, su, chown, chroot, mount, umount, systemctl, service, iptables,
find -exec, tee (with sensitive paths), backticks, $(...), process substitution,
I/O redirects to sensitive paths (/etc, ~/.ssh, ~/.aws, etc.)
```

---

## Subprocess Environment Isolation

`subprocess-env.ts` — the credential isolation boundary:

### Allowed through (whitelist)
- System: HOME, USER, LOGNAME, SHELL, PATH, TERM, HOSTNAME, NODE_ENV
- Temp: TMPDIR, TMP, TEMP
- Locale: LANG (plus LC_* prefix)
- Proxy: HTTP_PROXY, HTTPS_PROXY, NO_PROXY (and lowercase variants)
- TLS: SSL_CERT_FILE, SSL_CERT_DIR, NODE_EXTRA_CA_CERTS
- Toolchain: DOCKER_HOST, KUBECONFIG, SSH_AUTH_SOCK, RUST_LOG, RUST_BACKTRACE
- Prefixes: LC_*, XDG_*, OPENSHELL_*, GRPC_*

### Blocked (everything else, including)
- NVIDIA_API_KEY, OPENAI_API_KEY, ANTHROPIC_API_KEY
- AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
- GITHUB_TOKEN, HF_TOKEN, SLACK_BOT_TOKEN, DISCORD_BOT_TOKEN
- All other env vars not in the whitelist

### Credential Injection
Credentials needed by a subprocess are passed via the `extra` parameter:
```typescript
buildSubprocessEnv({ OPENAI_API_KEY: credential })
```

---

## API Surface (Port 42617)

### OpenAI-Compatible Endpoints
```
POST /v1/chat/completions     # Chat completion
GET  /v1/models               # List available models
GET  /health                  # Health check
```

### ZeroClaw-Specific Endpoints
```
GET  /api/sessions            # List sessions
POST /api/sessions            # Create session
DELETE /api/sessions/:id      # Delete session
POST /api/agent/chat          # Agent chat (streaming)
GET  /api/config              # Current config
GET  /api/skills              # List installed skills
POST /api/skills/install      # Install skill from ClawHub
```

### Web UI
Served from the same port (42617). React SPA with:
- Agent chat interface
- Session management
- Model selector
- Skills browser
- Config editor
- Cron manager
- Memory browser
- Log viewer

---

## Test Targets

| System | IP | RAM | User | Path |
|--------|-----|-----|------|------|
| zeropi | 10.0.0.56 | 2GB | pi | ~/nclawzero |
| clawpi | 10.0.0.54 | 8GB | pi | ~/nclawzero |

SSH: `sshpass -p "<sshpass-redacted>" ssh pi@10.0.0.5{4,6}`

### V7.1 Test Battery
```bash
cd ~/nclawzero
npx vitest run --project plugin --project cli
```

Current status: 1852 tests passing, 0 failures.

---

## Yocto Build (meta-nclawzero)

Building on ARGOS (10.0.0.22):
```
/mnt/argonas/nclawzero-yocto/
  poky/                    (scarthgap)
  meta-openembedded/       (scarthgap)
  meta-raspberrypi/        (scarthgap)
  meta-nclawzero/          (main)
  build-rpi/               (MACHINE=raspberrypi4-64)
```

Build: `bitbake core-image-minimal` running now. `nclawzero-image` next.
Output: `/home/jasonperlow/yocto-tmp/build-rpi-tmp/deploy/images/raspberrypi4-64/`
