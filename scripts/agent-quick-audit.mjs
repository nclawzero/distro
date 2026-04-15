/**
 * Quick nclawzero audit — runs a single agent to review the zeroclaw agent
 * integration for issues. Uses the agent-sdk-template infrastructure.
 */
import { writeFileSync, readFileSync, existsSync, appendFileSync, mkdirSync, unlinkSync, rmSync } from 'fs';
import { join, dirname, resolve } from 'path';
import { fileURLToPath } from 'url';
import { execSync } from 'child_process';
import { platform } from 'os';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, '..');
const DEBUG_LOG = join(ROOT, 'agent-sdk-activity.log');

if (!process.env.ANTHROPIC_API_KEY && process.env.NVIDIA_INFERENCE_KEY)
  process.env.ANTHROPIC_API_KEY = process.env.NVIDIA_INFERENCE_KEY;
if (!process.env.ANTHROPIC_BASE_URL)
  process.env.ANTHROPIC_BASE_URL = 'https://inference-api.nvidia.com';
process.env.DEBUG_CLAUDE_AGENT_SDK = '1';
if (!process.env.ANTHROPIC_TIMEOUT) process.env.ANTHROPIC_TIMEOUT = '600000';

if (!process.env.ANTHROPIC_API_KEY) {
  console.error('Set NVIDIA_INFERENCE_KEY env var. Get yours at https://inference.nvidia.com/key-management');
  process.exit(1);
}

const MODEL = process.env.AUDIT_MODEL || 'azure/anthropic/claude-sonnet-4-6';

try { await import('@anthropic-ai/claude-agent-sdk'); } catch {
  console.log('Installing @anthropic-ai/claude-agent-sdk...');
  execSync('npm install @anthropic-ai/claude-agent-sdk', { stdio: 'inherit', cwd: ROOT });
}
const { query } = await import('@anthropic-ai/claude-agent-sdk');

function _log(msg) {
  const line = `[${new Date().toISOString()}] ${msg}`;
  console.log(line);
  try { appendFileSync(DEBUG_LOG, line + '\n'); } catch {}
}

_log(`Quick Audit — model=${MODEL} cwd=${ROOT}`);

const agentFiles = execSync('find agents/zeroclaw/ -type f | sort', { cwd: ROOT, encoding: 'utf-8' });
const testFiles = execSync('find test/ -name "*.test.*" | sort', { cwd: ROOT, encoding: 'utf-8' });
const recentHarness = execSync('ls -t ~/.nclawzero-harness/runs/run_*.json 2>/dev/null | head -1', { encoding: 'utf-8' }).trim();
const harnessData = recentHarness ? readFileSync(recentHarness, 'utf-8') : '{"summary":{"total":0}}';
const harnessSummary = JSON.parse(harnessData).summary;

const prompt = `You are auditing the nclawzero project — a research project that runs ZeroClaw agents inside OpenShell sandboxes on resource-constrained devices.

Working directory: ${ROOT}

## Agent Files
${agentFiles}

## Test Files  
${testFiles}

## Latest Test Harness Results
${JSON.stringify(harnessSummary, null, 2)}

## Your Task

Do a quick audit of the ZeroClaw agent integration under agents/zeroclaw/. 
Read the key files (Dockerfile, Dockerfile.base, start.sh, generate-config.ts, manifest.yaml).

Write a report to ${ROOT}/zeroclaw-agent-audit.md covering:

1. **Security**: Any hardening gaps in the container (privilege separation, capability drops, config integrity)
2. **Reliability**: Single points of failure, missing health checks, crash recovery
3. **Test gaps**: What's tested vs what should be tested but isn't
4. **Upstream compatibility**: Anything that would break if NemoClaw upstream changes their agent manifest format

Keep it concise — bullet points, not paragraphs. Focus on actionable findings.`;

_log('Starting audit agent...');
let toolCalls = 0, resultText = '';
const start = Date.now();

try {
  for await (const message of query({
    prompt,
    options: {
      model: MODEL,
      allowedTools: ['Read', 'Write', 'Edit', 'Glob', 'Grep'],
      maxTurns: 30,
      settingSources: [],
      stderr: (line) => {
        const t = line.trim();
        if (t) _log(`CHILD: ${t}`);
      },
    },
  })) {
    if (message.type === 'assistant') {
      for (const block of message.message?.content ?? []) {
        if (block.type === 'tool_use') {
          toolCalls++;
          _log(`TOOL-${toolCalls}: ${block.name}(${JSON.stringify(block.input).slice(0, 80)})`);
        }
      }
    } else if ('result' in message) {
      resultText = message.result || '';
    }
  }
} catch (err) {
  _log(`ERROR: ${err.message}`);
}

const elapsed = Math.round((Date.now() - start) / 1000);
_log(`DONE: ${toolCalls} tools, ${elapsed}s`);
if (existsSync(join(ROOT, 'zeroclaw-agent-audit.md'))) {
  _log('Audit report written to zeroclaw-agent-audit.md');
} else {
  _log('WARNING: No audit report file was written');
}
