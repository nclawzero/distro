// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-FileCopyrightText: Copyright (c) 2026 Jason Perlow. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

/**
 * ╔══════════════════════════════════════════════════════════════════════╗
 * ║  AGENT TEST RUNNER — nclawzero Test Analysis Suite                  ║
 * ║                                                                    ║
 * ║  Three parallel agents that analyze test results, upstream drift,   ║
 * ║  and coverage gaps for the nclawzero project.                      ║
 * ╚══════════════════════════════════════════════════════════════════════╝
 *
 * WHAT THIS DOES:
 *   Runs three agents in parallel via the Claude Agent SDK:
 *
 *   1. TestAnalyzer   — Reads the latest test harness result from
 *                       ~/.nclawzero-harness/runs/ and writes a failure/skip
 *                       analysis to test-analysis-report.md.
 *
 *   2. UpstreamDrift  — Compares our test suite against upstream NemoClaw's
 *                       test structure and writes upstream-drift-report.md.
 *
 *   3. CoverageGap    — Reads source files under agents/zeroclaw/ and
 *                       src/lib/agent-*.ts, identifies untested code paths,
 *                       and writes coverage-gap-report.md.
 *
 * HOW TO RUN:
 *   node scripts/agent-test-runner.mjs
 *
 * REQUIREMENTS:
 *   - Node.js 18+
 *   - NVIDIA_INFERENCE_KEY environment variable
 *   - @anthropic-ai/claude-agent-sdk (auto-installed if missing)
 *
 * INFRASTRUCTURE:
 *   Copied from agent-sdk-template.mjs. Self-contained — no imports from
 *   the template. See agent-sdk-template.mjs for the full rule set and
 *   architectural documentation.
 */

import { writeFileSync, readFileSync, existsSync, appendFileSync, mkdirSync, unlinkSync, rmSync, readdirSync, statSync } from 'fs';
import { join, dirname, resolve, relative } from 'path';
import { fileURLToPath } from 'url';
import { platform, homedir } from 'os';

// ─── SETUP (copied from agent-sdk-template.mjs) ─────────────────────

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, '..');
const DEBUG_LOG = join(ROOT, 'agent-sdk-activity.log');
const IS_WINDOWS = platform() === 'win32';
const IS_MAC = platform() === 'darwin';

if (!process.env.ANTHROPIC_API_KEY && process.env.NVIDIA_INFERENCE_KEY)
  process.env.ANTHROPIC_API_KEY = process.env.NVIDIA_INFERENCE_KEY;
if (!process.env.ANTHROPIC_BASE_URL)
  process.env.ANTHROPIC_BASE_URL = 'https://inference-api.nvidia.com';

process.env.DEBUG_CLAUDE_AGENT_SDK = '1';
if (!process.env.ANTHROPIC_TIMEOUT) process.env.ANTHROPIC_TIMEOUT = '600000';

// ─── TCP KEEPALIVE (automatic) ───────────────────────────────────────
import { execSync as _execSync } from 'child_process';
try {
  if (IS_MAC) {
    _execSync('sysctl -w net.inet.tcp.keepidle=30 net.inet.tcp.keepintvl=10 net.inet.tcp.keepcnt=5 2>/dev/null', { stdio: 'ignore' });
  } else if (platform() !== 'win32') {
    _execSync('sysctl -w net.ipv4.tcp_keepalive_time=30 net.ipv4.tcp_keepalive_intvl=10 net.ipv4.tcp_keepalive_probes=5 2>/dev/null', { stdio: 'ignore' });
  }
} catch { /* needs sudo — warn but continue */ }

function _resetKeepalive() {
  try {
    if (IS_MAC) {
      _execSync('sysctl -w net.inet.tcp.keepidle=7200 net.inet.tcp.keepintvl=75 net.inet.tcp.keepcnt=8 2>/dev/null', { stdio: 'ignore' });
    } else if (platform() !== 'win32') {
      _execSync('sysctl -w net.ipv4.tcp_keepalive_time=7200 net.ipv4.tcp_keepalive_intvl=75 net.ipv4.tcp_keepalive_probes=8 2>/dev/null', { stdio: 'ignore' });
    }
  } catch { /* best effort */ }
}

if (!process.env.ANTHROPIC_API_KEY) {
  console.error('');
  console.error('╔══════════════════════════════════════════════════════════════╗');
  console.error('║  NVIDIA_INFERENCE_KEY not found in your environment.        ║');
  console.error('╚══════════════════════════════════════════════════════════════╝');
  console.error('');
  console.error('Get your key: https://inference.nvidia.com/key-management');
  console.error('Then: export NVIDIA_INFERENCE_KEY="your-key-here"');
  console.error('');
  process.exit(1);
}

const PRIMARY_MODEL = process.env.AUDIT_MODEL || 'azure/anthropic/claude-sonnet-4-6';
const FALLBACK_MODEL = PRIMARY_MODEL.replace('azure/', 'aws/');
let MODEL = PRIMARY_MODEL;

// Auto-install SDK if missing
try {
  await import('@anthropic-ai/claude-agent-sdk');
} catch {
  console.log('Installing @anthropic-ai/claude-agent-sdk...');
  const { execSync } = await import('node:child_process');
  execSync('npm install @anthropic-ai/claude-agent-sdk', { stdio: 'inherit' });
}
const { query } = await import('@anthropic-ai/claude-agent-sdk');

// SDK version check
const TESTED_SDK_RANGE = { min: '0.2.90', max: '0.3.99' };
try {
  const sdkPkg = JSON.parse(readFileSync(join(ROOT, 'node_modules/@anthropic-ai/claude-agent-sdk/package.json'), 'utf-8'));
  const ver = sdkPkg.version;
  if (ver < TESTED_SDK_RANGE.min || ver > TESTED_SDK_RANGE.max)
    _log(`SDK VERSION WARNING: installed ${ver}, tested ${TESTED_SDK_RANGE.min}-${TESTED_SDK_RANGE.max}. Behavior may differ.`);
  else _log(`SDK version: ${ver} (within tested range)`);
} catch { _log('SDK version: could not determine'); }

process.on('uncaughtException', (e) => { _log(`FATAL UNCAUGHT: ${e.message}\n${e.stack}`); process.exit(99); });
process.on('unhandledRejection', (e) => { _log(`FATAL UNHANDLED: ${e?.message || e}`); process.exit(98); });
process.on('exit', (code) => { _resetKeepalive(); _log(`PROCESS EXIT code=${code}`); });

function _log(msg) {
  const line = `[${new Date().toISOString()}] ${msg}`;
  console.log(line);
  try { appendFileSync(DEBUG_LOG, line + '\n'); } catch { /* best effort */ }
}

// ─── ALLOWED TOOLS ───────────────────────────────────────────────────

const ALLOWED_TOOLS = ['Read', 'Write', 'Edit', 'Glob', 'Grep'];

// ─── DATA BROKERING ──────────────────────────────────────────────────

const PROMPT_TOKEN_BUDGET = 8000;
const DATA_INLINE_MAX = 4000;
const TEMP_DIR = join(ROOT, '.tmp-agent-data');

function estimateTokens(text) { return Math.ceil(text.length / 4); }

async function prepareData(label, dataSpec) {
  if (!dataSpec || typeof dataSpec !== 'object') return { block: '', tempFiles: [] };
  const tempFiles = [], blocks = [];
  for (const [name, fetchFn] of Object.entries(dataSpec)) {
    if (typeof fetchFn !== 'function') continue;
    let raw;
    try { raw = fetchFn(); if (typeof raw !== 'string') raw = JSON.stringify(raw, null, 2); }
    catch (err) { _log(`[${label}] DATA "${name}" fetch failed: ${err.message}`); blocks.push(`=== DATA: ${name} (FETCH FAILED: ${err.message}) ===\n`); continue; }
    const tokens = estimateTokens(raw);
    _log(`[${label}] DATA "${name}": ${raw.split('\n').length} lines, ~${tokens} tokens`);
    if (tokens <= DATA_INLINE_MAX) {
      blocks.push(`=== DATA: ${name} (${tokens} tokens, inline) ===\n${raw}\n=== END ${name} ===\n`);
    } else {
      mkdirSync(TEMP_DIR, { recursive: true });
      const tempPath = join(TEMP_DIR, `${label}-${name}-${Date.now()}.txt`);
      writeFileSync(tempPath, raw); tempFiles.push(tempPath);
      _log(`[${label}] DATA "${name}": too large for inline (${tokens} tokens) — summarizing`);
      let summary;
      try {
        const summaryPrompt = `Summarize this data concisely for another AI agent. Keep key details (IDs, names, statuses, counts). Under 80 lines.\n\n${raw.slice(0, 30000)}`;
        let summaryResult = '';
        for await (const msg of query({ prompt: summaryPrompt, options: { model: MODEL, allowedTools: [], maxTurns: 1, settingSources: [] } }))
          if ('result' in msg) summaryResult = msg.result || '';
        summary = summaryResult || raw.slice(0, DATA_INLINE_MAX * 4);
        _log(`[${label}] DATA "${name}": summarized to ~${estimateTokens(summary)} tokens`);
      } catch (err) {
        _log(`[${label}] DATA "${name}": summarizer failed (${err.message}) — using truncation`);
        summary = raw.slice(0, DATA_INLINE_MAX * 4) + '\n... (truncated)';
      }
      blocks.push(`=== DATA: ${name} (summarized — full data at ${tempPath}, use Grep for details) ===\n${summary}\n=== END ${name} ===\n`);
    }
  }
  return { block: blocks.join('\n'), tempFiles };
}

function cleanupTempFiles(tempFiles) {
  for (const f of tempFiles) { try { unlinkSync(f); } catch {} }
  try { rmSync(TEMP_DIR, { recursive: true, force: true }); } catch {}
}

// ─── AGENT RUNNER ────────────────────────────────────────────────────

const VERIFY_FOOTER = `

IMPORTANT RULES FOR THIS AGENT:
- Use ONLY these tools: Read, Write, Edit, Glob, Grep. NO Bash. NO Agent sub-tasks.
- All data you need is already in your prompt above. Do NOT try to fetch more.
- Read whole files. Do NOT chunk into small pieces.
- Write incrementally if producing large output — one section at a time.

MANDATORY SELF-VERIFICATION AND SELF-CORRECTION:

After EVERY file write or edit:
1. Read the file back immediately.
2. Confirm your change is present and correct.
3. If the change is NOT present or is wrong: fix it now, then re-read to verify again.
4. Repeat until the file is correct. Do not move on until it is.

Before returning your final result you MUST complete this checklist:
1. List every file you were asked to create or modify.
2. For each file: read it and confirm it matches the task requirements.
3. If ANY file is missing, incomplete, or wrong: fix it now.
4. Return a verification table as the LAST thing in your response:

| File | Status | Check |
|------|--------|-------|
| path/to/file | VERIFIED or FIXED | what was confirmed |

You may NOT return your result until every file shows VERIFIED or FIXED.
If you cannot fix a problem, report it as FAILED with the reason — but attempt the fix first.`;

const INITIAL_RESPONSE_TIMEOUT_MS = 30_000;
const SILENCE_TIMEOUT_MS = 423_000;
const MAX_RETRIES = 2;
const API_RETRY_DELAY_MS = 10_000;

async function runAgent(label, prompt, options = {}) {
  const maxTurns = options.maxTurns || 50;
  const retries = options.retries ?? MAX_RETRIES;
  const attempt = options._attempt || 1;
  const agentModel = options._model || options.model || MODEL;
  const start = Date.now();
  let toolCalls = 0, resultText = '', errorMsg = null, lastActivity = Date.now();
  let silenceKilled = false, streamStarted = false, failureType = null;
  const filesWritten = [], writeErrors = [];

  const dataResult = await prepareData(label, options.data);
  const dataBlock = dataResult.block ? '\n' + dataResult.block + '\n' : '';
  const totalTokens = estimateTokens(prompt) + estimateTokens(dataBlock) + estimateTokens(VERIFY_FOOTER);
  _log(`[${label}] PROMPT: ~${totalTokens} tokens sending to proxy`);

  const fullPrompt = dataBlock + prompt + VERIFY_FOOTER;
  const elapsed = () => Math.round((Date.now() - start) / 1000);
  _log(`[${label}] STARTING model=${agentModel} maxTurns=${maxTurns}${attempt > 1 ? ` (retry ${attempt})` : ''}`);

  const memWatch = setInterval(() => {
    const rss = Math.round(process.memoryUsage().rss / 1024 / 1024);
    if (rss > 500) _log(`[${label}] MEMORY: parent RSS ${rss}MB`);
  }, 30000);

  const heartbeat = setInterval(() => {
    const silence = Date.now() - lastActivity, silenceSec = Math.round(silence / 1000);
    const rss = Math.round(process.memoryUsage().rss / 1024 / 1024);
    _log(`[${label}] heartbeat ${elapsed()}s | ${toolCalls} tools | silent ${silenceSec}s | RSS ${rss}MB`);
    const timeout = !streamStarted ? INITIAL_RESPONSE_TIMEOUT_MS : (options.silenceTimeoutMs || SILENCE_TIMEOUT_MS);
    if (silence > timeout) {
      silenceKilled = true;
      failureType = !streamStarted ? 'api_no_response' : (toolCalls === 0 ? 'model_thinking_timeout' : 'mid_work_silence');
      const label2 = failureType === 'api_no_response' ? 'API NO RESPONSE' : failureType === 'model_thinking_timeout' ? 'MODEL THINKING TIMEOUT' : 'SILENCE TIMEOUT';
      _log(`[${label}] ${label2} — ${silenceSec}s, ${toolCalls} tools, stream=${streamStarted}. Killing.`);
      clearInterval(heartbeat);
    }
  }, 15000);

  try {
    for await (const message of query({ prompt: fullPrompt, options: {
      model: agentModel, allowedTools: options.tools || ALLOWED_TOOLS, maxTurns, settingSources: [],
      stderr: (line) => {
        const trimmed = line.trim();
        if (!trimmed) return;
        _log(`[${label}] CHILD: ${trimmed}`);
        if (trimmed.includes('Stream started')) { lastActivity = Date.now(); streamStarted = true; }
      },
    }})) {
      if (silenceKilled) break;
      lastActivity = Date.now();
      if (message.type === 'assistant') {
        for (const block of message.message?.content ?? []) {
          if (block.type === 'tool_use') {
            toolCalls++;
            const input = JSON.stringify(block.input).slice(0, 100);
            _log(`[${label}] ${elapsed()}s | TOOL-${toolCalls}: ${block.name}(${input})`);
            if (block.name === 'Write' && block.input?.file_path) filesWritten.push(block.input.file_path);
          } else if (block.type === 'tool_result' && block.is_error) {
            const errText = typeof block.content === 'string' ? block.content : JSON.stringify(block.content);
            if (errText.includes('EPERM') || errText.includes('permission')) {
              writeErrors.push(errText.slice(0, 200));
              _log(`[${label}] ${elapsed()}s | WRITE ERROR: ${errText.slice(0, 150)}`);
            }
          } else if (block.type === 'text' && block.text) {
            _log(`[${label}] ${elapsed()}s | TEXT: ${block.text.slice(0, 150)}${block.text.length > 150 ? '...' : ''}`);
          }
        }
      } else if (message.type === 'system' && message.subtype === 'init') {
        _log(`[${label}] ${elapsed()}s | INIT: session=${message.session_id}`);
      } else if ('result' in message) {
        resultText = message.result || '';
        _log(`[${label}] ${elapsed()}s | RESULT: ${resultText.slice(0, 200)}${resultText.length > 200 ? '...' : ''}`);
      }
    }
  } catch (err) {
    errorMsg = err.message || String(err);
    if (errorMsg.includes('maximum number of turns')) failureType = 'max_turns';
    else if (errorMsg.includes('SIGKILL')) failureType = 'oom_killed';
    else if (errorMsg.includes('exited with code')) failureType = 'child_crash';
    else if (errorMsg.includes('terminated by signal')) failureType = 'child_signal';
    else failureType = 'unknown_error';
    _log(`[${label}] ${elapsed()}s | CATCH (${failureType}): ${errorMsg}`);
  } finally { clearInterval(heartbeat); clearInterval(memWatch); }

  if (silenceKilled && !failureType) failureType = !streamStarted ? 'api_no_response' : 'mid_work_silence';
  if (silenceKilled) errorMsg = `${failureType}: silent for ${Math.round((Date.now() - lastActivity) / 1000)}s with ${toolCalls} tools`;

  const canRetry = attempt <= retries && (silenceKilled || failureType === 'max_turns');
  if (canRetry) {
    _log(`[${label}] AUTO-RETRY (${failureType}) — attempt ${attempt + 1}/${retries + 1}`);
    _log(`[${label}]   Files written so far: ${filesWritten.length ? filesWritten.join(', ') : 'none'}`);
    let retryOpts = { ...options, _attempt: attempt + 1 };
    if (failureType === 'api_no_response') {
      _log(`[${label}]   Waiting ${API_RETRY_DELAY_MS / 1000}s before retry...`);
      await new Promise(r => setTimeout(r, API_RETRY_DELAY_MS));
      if (attempt >= 2 && agentModel === PRIMARY_MODEL) {
        _log(`[${label}]   Switching to fallback provider: ${FALLBACK_MODEL}`);
        retryOpts._model = FALLBACK_MODEL;
      }
    }
    if (failureType === 'max_turns') retryOpts.maxTurns = Math.min(maxTurns + 10, 60);
    const retryHint = filesWritten.length
      ? `\n\nRETRY: Previous attempt wrote: ${filesWritten.join(', ')}. Read them, focus on what's NOT done. Smaller steps.`
      : `\n\nRETRY: Previous attempt failed (${failureType}). Work in smaller steps.`;
    return runAgent(label, prompt + retryHint, retryOpts);
  }

  const status = (errorMsg || silenceKilled) ? 'FAILED' : 'OK';
  const verdict = status === 'OK'
    ? `ENDED: completed normally | ${toolCalls} tools | ${elapsed()}s`
    : `ENDED: ${failureType || 'unknown'} | ${toolCalls} tools | ${elapsed()}s | ${errorMsg?.slice(0, 100)}`;
  _log(`[${label}] ${verdict}`);

  const cleaned = dataResult.tempFiles.length;
  cleanupTempFiles(dataResult.tempFiles);
  if (cleaned) _log(`[${label}] CLEANUP: removed ${cleaned} temp file(s)`);
  else _log(`[${label}] CLEANUP: no temp files`);

  const agentResult = { label, status, elapsed: elapsed(), toolCalls, error: errorMsg, result: resultText, filesWritten, failureType, verdict, writeErrors };
  _allResults.push(agentResult);
  return agentResult;
}

// ─── PARALLEL + SEQUENTIAL RUNNERS ──────────────────────────────────

async function runParallel(agents) {
  _log(`Running ${agents.length} agents in parallel...`);
  const results = await Promise.all(agents.map(a => runAgent(a.label, a.prompt, { ...a.options, data: a.data })));
  _log('Parallel batch complete:');
  for (const r of results) _log(`  ${r.label.padEnd(25)} ${r.status.padEnd(8)} ${(r.elapsed + 's').padStart(8)} ${String(r.toolCalls).padStart(6)} tools`);
  _log(`${results.filter(r => r.status === 'OK').length}/${results.length} succeeded`);
  return results;
}

async function runSequential(agents) {
  _log(`Running ${agents.length} agents sequentially...`);
  const results = [];
  for (const a of agents) { results.push(await runAgent(a.label, a.prompt, { ...a.options, data: a.data })); }
  return results;
}

// ─── RUN SUMMARY + PROGRESS ─────────────────────────────────────────

const ERROR_ADVICE = {
  api_no_response: 'Proxy did not respond after 2 retries (including backup provider). Check proxy status on #nv-inference Slack, then re-run.',
  model_thinking_timeout: 'Model thought longer than silence timeout before acting. Task may need smaller agents (Rule 10).',
  mid_work_silence: 'Model thinking too long mid-work, proxy killed the stream. Split into smaller agents.',
  max_turns: 'Ran out of conversation turns. Increase maxTurns or simplify the task.',
  oom_killed: 'Out of memory (SIGKILL). Reduce the number of large files the agent reads.',
  child_crash: 'SDK child process crashed. Check CHILD stderr lines in logs.',
  child_signal: 'Child process terminated by signal. Check signal name in logs.',
  unknown_error: 'Unexpected error. Check the CATCH line in logs for the full message.',
};

const _allResults = [];
const _startTime = Date.now();

function writeRunSummary() {
  if (_allResults.length === 0) return;
  const summaryPath = join(ROOT, 'agent-sdk-last-run.md');
  const ok = _allResults.filter(r => r.status === 'OK').length;
  const failed = _allResults.filter(r => r.status === 'FAILED');
  const lines = [
    '# Agent Test Runner — Last Run Summary', '',
    `> Generated: ${new Date().toISOString()}`,
    `> Agents: ${_allResults.length} total, ${ok} succeeded, ${failed.length} failed`, '',
    '## Results', '',
    '| Agent | Status | Time | Tools | Failure | Advice |',
    '|-------|--------|------|-------|---------|--------|',
  ];
  for (const r of _allResults) {
    const advice = r.failureType ? (ERROR_ADVICE[r.failureType] || 'Check logs.').slice(0, 80) : '—';
    lines.push(`| ${r.label} | ${r.status} | ${r.elapsed}s | ${r.toolCalls} | ${r.failureType || '—'} | ${r.status === 'OK' ? '—' : advice} |`);
  }
  if (failed.length) {
    lines.push('', '## Failed Agents — What To Fix', '');
    for (const r of failed) {
      lines.push(`### ${r.label}`, `- **Failure type:** ${r.failureType}`, `- **Verdict:** ${r.verdict}`, `- **Advice:** ${ERROR_ADVICE[r.failureType] || 'Check agent-sdk-activity.log'}`, '');
      if (r.writeErrors?.length) lines.push(`- **Write errors:** ${r.writeErrors.join('; ')}`);
      if (r.filesWritten?.length) lines.push(`- **Partial output:** ${r.filesWritten.join(', ')}`);
    }
  }
  lines.push('', '*Full logs: agent-sdk-activity.log*');
  try { writeFileSync(summaryPath, lines.join('\n')); _log(`RUN SUMMARY: ${summaryPath}`); } catch (err) { _log(`RUN SUMMARY write failed: ${err.message}`); }
}

const PROGRESS_PATH = join(ROOT, 'agent-sdk-progress.md');
const _progressTimer = setInterval(() => {
  const ok = _allResults.filter(r => r.status === 'OK').length;
  const failed = _allResults.filter(r => r.status === 'FAILED').length;
  const running = _allResults.length === 0 ? 'starting...' : `${ok} done, ${failed} failed`;
  const rss = Math.round(process.memoryUsage().rss / 1024 / 1024);
  const uptime = Math.round((Date.now() - _startTime) / 1000);
  const lines = [
    '# Agent Test Runner — In Progress', '',
    `> Updated: ${new Date().toISOString()}`,
    `> Running for: ${uptime}s | Status: ${running} | Memory: ${rss}MB`, '',
    '## Completed So Far', '',
  ];
  for (const r of _allResults) lines.push(`- **${r.label}**: ${r.status} (${r.elapsed}s, ${r.toolCalls} tools)${r.failureType ? ` — ${r.failureType}` : ''}`);
  if (_allResults.length === 0) lines.push('- _(waiting for first agent to finish)_');
  try { writeFileSync(PROGRESS_PATH, lines.join('\n')); } catch {}
}, 120_000);

process.on('exit', () => { writeRunSummary(); clearInterval(_progressTimer); try { unlinkSync(PROGRESS_PATH); } catch {} });

// ═══════════════════════════════════════════════════════════════════════
// DATA COLLECTION — Gather everything agents need BEFORE they start
// ═══════════════════════════════════════════════════════════════════════

const HARNESS_DIR = join(homedir(), '.nclawzero-harness', 'runs');

/**
 * Find the most recent run_*.json in the harness directory.
 * Returns the file contents as a string, or an error message.
 */
function loadLatestHarnessRun() {
  if (!existsSync(HARNESS_DIR)) {
    return JSON.stringify({ error: `Harness directory not found: ${HARNESS_DIR}. Run 'npm test' with the test harness first.` });
  }
  const files = readdirSync(HARNESS_DIR)
    .filter(f => f.startsWith('run_') && f.endsWith('.json'))
    .sort()
    .reverse();
  if (files.length === 0) {
    return JSON.stringify({ error: 'No run_*.json files found in harness directory.' });
  }
  const latest = files[0];
  _log(`[DataBroker] Latest harness run: ${latest}`);
  return readFileSync(join(HARNESS_DIR, latest), 'utf-8');
}

/**
 * Load all harness runs (for flaky test detection).
 * Returns a JSON array of {id, summary} for each run, plus the full latest.
 */
function loadAllHarnessRuns() {
  if (!existsSync(HARNESS_DIR)) return JSON.stringify([]);
  const files = readdirSync(HARNESS_DIR)
    .filter(f => f.startsWith('run_') && f.endsWith('.json'))
    .sort()
    .reverse();
  const runs = [];
  for (const f of files.slice(0, 10)) { // cap at 10 most recent
    try {
      const data = JSON.parse(readFileSync(join(HARNESS_DIR, f), 'utf-8'));
      runs.push({ id: data.id || f, timestamp: data.timestamp, summary: data.summary });
    } catch { /* skip malformed */ }
  }
  return JSON.stringify(runs, null, 2);
}

/**
 * Recursively collect file paths matching a pattern under a directory.
 */
function collectFiles(dir, extensions = ['.ts', '.js', '.rs', '.sh']) {
  const results = [];
  if (!existsSync(dir)) return results;
  function walk(d) {
    for (const entry of readdirSync(d, { withFileTypes: true })) {
      const full = join(d, entry.name);
      if (entry.isDirectory() && !entry.name.startsWith('.') && entry.name !== 'node_modules') {
        walk(full);
      } else if (entry.isFile() && extensions.some(ext => entry.name.endsWith(ext))) {
        results.push(relative(ROOT, full));
      }
    }
  }
  walk(dir);
  return results.sort();
}

/**
 * Collect our test file tree.
 */
function collectOurTests() {
  const tests = [
    ...collectFiles(join(ROOT, 'test'), ['.test.ts', '.test.js']),
    ...collectFiles(join(ROOT, 'src', 'lib'), ['.test.ts', '.test.js']),
    ...collectFiles(join(ROOT, 'nemoclaw', 'src'), ['.test.ts', '.test.js']),
  ];
  return tests.join('\n');
}

/**
 * Collect upstream NemoClaw test file tree (if upstream remote exists).
 * Falls back to reading from the known upstream test structure in docs.
 */
function collectUpstreamTests() {
  // Try to list upstream test files from git
  try {
    const upstream = _execSync(
      'git ls-tree -r --name-only origin/main -- test/ src/lib/ nemoclaw/src/ 2>/dev/null || ' +
      'git ls-tree -r --name-only upstream/main -- test/ src/lib/ nemoclaw/src/ 2>/dev/null',
      { encoding: 'utf-8', cwd: ROOT, timeout: 10000 }
    ).trim();
    if (upstream) {
      const testFiles = upstream.split('\n').filter(f => f.includes('.test.'));
      if (testFiles.length > 0) return testFiles.join('\n');
    }
  } catch { /* no upstream remote — fall through */ }

  // Try fetching from NemoClaw upstream via git remote
  try {
    const remotes = _execSync('git remote -v', { encoding: 'utf-8', cwd: ROOT, timeout: 5000 });
    // Check if there is an NVIDIA/NemoClaw remote
    const upstreamLine = remotes.split('\n').find(l => l.includes('NVIDIA/NemoClaw') || l.includes('nvidia/nemoclaw'));
    if (upstreamLine) {
      const remoteName = upstreamLine.split(/\s/)[0];
      const upstream = _execSync(
        `git ls-tree -r --name-only ${remoteName}/main -- test/ src/lib/ nemoclaw/src/ 2>/dev/null`,
        { encoding: 'utf-8', cwd: ROOT, timeout: 10000 }
      ).trim();
      if (upstream) {
        const testFiles = upstream.split('\n').filter(f => f.includes('.test.'));
        if (testFiles.length > 0) return testFiles.join('\n');
      }
    }
  } catch { /* no upstream remote */ }

  return '(upstream test listing unavailable — no upstream remote configured. Agent should use Grep/Glob to infer from CLAUDE.md or CONTRIBUTING.md references.)';
}

/**
 * Collect source files that should have test coverage.
 */
function collectSourceFiles() {
  const sources = [
    ...collectFiles(join(ROOT, 'agents', 'zeroclaw'), ['.ts', '.rs', '.sh']),
    ...collectFiles(join(ROOT, 'src', 'lib'), ['.ts']),
  ];
  // Filter out test files — we want source-only
  const sourceOnly = sources.filter(f => !f.includes('.test.'));
  return sourceOnly.join('\n');
}

/**
 * Collect src/lib/agent-*.ts files specifically.
 */
function collectAgentLibFiles() {
  const libDir = join(ROOT, 'src', 'lib');
  if (!existsSync(libDir)) return '';
  return readdirSync(libDir)
    .filter(f => f.startsWith('agent-') && f.endsWith('.ts') && !f.includes('.test.'))
    .map(f => join('src', 'lib', f))
    .join('\n');
}

// ═══════════════════════════════════════════════════════════════════════
// AGENTS — Three parallel analysis agents
// ═══════════════════════════════════════════════════════════════════════

_log('Agent Test Runner — nclawzero Test Analysis Suite');
_log(`Model: ${MODEL}`);
_log(`Fallback: ${FALLBACK_MODEL}`);
_log(`Proxy: ${process.env.ANTHROPIC_BASE_URL}`);
_log(`Key: ${process.env.ANTHROPIC_API_KEY ? 'set' : 'MISSING'}`);
_log(`Tools: ${ALLOWED_TOOLS.join(', ')}`);
_log(`Debug log: ${DEBUG_LOG}`);
_log(`Harness dir: ${HARNESS_DIR}`);
_log(`Project root: ${ROOT}`);

// ─── Agent 1: TestAnalyzer ──────────────────────────────────────────

const TestAnalyzer = {
  label: 'TestAnalyzer',
  data: {
    latestRun: () => loadLatestHarnessRun(),
    allRuns: () => loadAllHarnessRuns(),
  },
  options: { maxTurns: 30 },
  prompt: `You are a test analysis agent for the nclawzero project (an NVIDIA NemoClaw fork).

Your task: Analyze the latest test harness results and produce a comprehensive report.

The data provided to you contains:
- "latestRun": The full JSON from the most recent test harness run (run_*.json from ~/.nclawzero-harness/runs/).
  It has fields: id, timestamp, suite, duration_seconds, git_ref, git_branch, host, node_version,
  summary (total/passed/failed/skipped/pass_rate), and tests[] (each with name, file, suite, status, duration_ms, error).
- "allRuns": An array of {id, timestamp, summary} for up to 10 recent runs (for flaky detection).

Write your analysis to: ${join(ROOT, 'test-analysis-report.md')}

The report MUST include these sections:

## 1. Summary Table
A markdown table with columns: Metric | Value
Include: total tests, passed, failed, skipped, pass rate, duration, git ref, branch, host, node version, timestamp.

## 2. Failure Analysis
For EACH failed test (status: "fail" or "failed"):
- **Test name** and **file path**
- **Error message** (from the error field)
- **Root cause analysis**: Based on the error message, test name, and file path, infer the likely root cause.
  Look at the test file name to understand what subsystem is being tested.
- **Suggested fix**: A concrete, actionable suggestion for what to change and in which file.
- **File to edit**: The source file (not the test file) most likely to need the fix.

If there are zero failures, note that explicitly and celebrate the clean run.

## 3. Skip Analysis
For EACH skipped test (status: "skip" or "skipped"):
- **Test name** and **file path**
- **Why it is likely skipped**: Infer from the test name (e.g., "Brev E2E" tests are skipped because they
  require BREV_API_TOKEN and a cloud instance; tests with "remote VM" are environment-dependent).
- **Should it be unskipped?**: Recommend whether and how to enable it (e.g., "run on Brev cloud instance",
  "add mock", "needs BREV_API_TOKEN env var").

## 4. Flaky Test Detection
If multiple runs exist in allRuns, compare their summaries:
- Any test that passed in one run but failed/skipped in another is potentially flaky.
- List flaky candidates with the runs where they differed.
- If only one run exists, state that flaky detection requires multiple runs.

## 5. Recommendations
Top 3-5 actionable recommendations based on the analysis.

Write the full report to the file path above. Use clear markdown formatting.`,
};

// ─── Agent 2: UpstreamDrift ─────────────────────────────────────────

const UpstreamDrift = {
  label: 'UpstreamDrift',
  data: {
    ourTests: () => collectOurTests(),
    upstreamTests: () => collectUpstreamTests(),
  },
  options: { maxTurns: 40 },
  prompt: `You are an upstream drift analysis agent for the nclawzero project.

nclawzero is a fork of NVIDIA's NemoClaw project. Over time, our test suite may diverge from upstream.

The data provided to you contains:
- "ourTests": A newline-separated list of all test files in our repo (under test/, src/lib/, nemoclaw/src/).
- "upstreamTests": A newline-separated list of upstream NemoClaw test files (if available via git remote),
  OR a note that upstream listing is unavailable.

Your task: Compare the two test suites and write a drift report.

Write your analysis to: ${join(ROOT, 'upstream-drift-report.md')}

IF upstream test listing is available, the report MUST include:

## 1. Summary
- Total test files: ours vs upstream
- Tests in common (exist in both)
- Tests only in upstream (we are missing)
- Tests only in ours (our additions)

## 2. Missing from Our Suite
For each test file that upstream has but we do not:
- **File path** (upstream path)
- **Likely purpose**: Infer from filename what it tests
- **Priority**: High (security/core), Medium (feature), Low (nice-to-have)
- **Recommendation**: Whether to port it and estimated effort

## 3. Our Additions
For each test file we have that upstream does not:
- **File path**
- **Purpose**: Infer from filename
- **Upstream relevance**: Should this be contributed back?

## 4. Common Tests — Potential Divergence
For tests that exist in both (by filename match, ignoring path differences):
- Note that content comparison requires reading each file (which you can do with Read tool)
- For a sample of up to 5 common test files, use Read to check if our version has significant
  differences from what the upstream version likely tests (based on the file name).

## 5. Drift Risk Assessment
Overall drift risk: Low / Medium / High, with justification.

IF upstream test listing is NOT available:
- Use Glob to find all test files in our repo
- Read CLAUDE.md or CONTRIBUTING.md (at ${ROOT}) for references to upstream test structure
- List our test files organized by subsystem
- Note that upstream comparison requires configuring an upstream git remote:
  git remote add upstream https://github.com/NVIDIA/NemoClaw.git && git fetch upstream
- Provide what analysis you can with available information.

Write the full report to the file path above. Use clear markdown formatting.`,
};

// ─── Agent 3: CoverageGap ──────────────────────────────────────────

const CoverageGap = {
  label: 'CoverageGap',
  data: {
    sourceFiles: () => collectSourceFiles(),
    agentLibFiles: () => collectAgentLibFiles(),
    testFiles: () => collectOurTests(),
  },
  options: { maxTurns: 50 },
  prompt: `You are a test coverage gap analysis agent for the nclawzero project.

Your task: Identify source files and code paths that lack test coverage, then recommend new test cases.

The data provided to you contains:
- "sourceFiles": All non-test source files under agents/zeroclaw/ and src/lib/ (one per line).
- "agentLibFiles": Specifically the src/lib/agent-*.ts files (the agent runtime layer).
- "testFiles": All test files in the project (one per line).

Write your analysis to: ${join(ROOT, 'coverage-gap-report.md')}

APPROACH:
1. First, match each source file to its corresponding test file (if any).
   Convention: foo.ts -> foo.test.ts (co-located in src/lib/) or test/foo.test.ts (root test dir).
2. Identify source files with NO corresponding test file.
3. For key source files (especially agent-*.ts and agents/zeroclaw/*), use Read to examine the code
   and identify specific exported functions, classes, or code paths that should be tested.
4. Do NOT try to read every file — focus on the untested ones and the agent-related ones.
   Read whole files, not small chunks.

The report MUST include:

## 1. Coverage Overview
A markdown table:
| Source File | Has Test? | Test File | Gap Level |
Where Gap Level is: None (fully tested), Partial (test exists but coverage likely incomplete), Full (no test file at all).

## 2. Untested Source Files
For each source file with no corresponding test:
- **File path**
- **Purpose**: Brief description based on filename and/or reading the file
- **Priority**: Critical (security/agent runtime), High (core functionality), Medium (utility), Low (config/types)
- **Why it matters**: What could break without tests

## 3. Agent Runtime Coverage Deep Dive
For each agent-related file (agent-defs.ts, agent-onboard.ts, agent-runtime.ts, and agents/zeroclaw/*):
- Read the file
- List the key exported functions/classes
- For each: does a test exist that exercises it? If not, what test case would you write?
- Focus on: error paths, edge cases, security-sensitive operations

## 4. Recommended New Test Cases
For each recommended test, provide:
- **Test file to create**: Path where the test should live
- **Test name**: describe/it block name
- **What it tests**: The specific function or code path
- **Why**: Why this test matters
- **Sketch**: A 3-5 line pseudocode sketch of the test logic

Prioritize recommendations by:
1. Security-sensitive code (credential handling, SSRF validation, sandbox isolation)
2. Agent runtime (the code that runs agents in sandboxes)
3. Core CLI functionality
4. Utility code

## 5. Summary
Total gaps found, top 5 most critical gaps, estimated effort to close them.

Write the full report to the file path above. Use clear markdown formatting.`,
};

// ═══════════════════════════════════════════════════════════════════════
// RUN — All three agents in parallel
// ═══════════════════════════════════════════════════════════════════════

_log('Starting 3 analysis agents in parallel: TestAnalyzer, UpstreamDrift, CoverageGap');

const results = await runParallel([TestAnalyzer, UpstreamDrift, CoverageGap]);

// Print final summary
_log('');
_log('═══════════════════════════════════════════════════════════════════');
_log('AGENT TEST RUNNER — COMPLETE');
_log('═══════════════════════════════════════════════════════════════════');
const okCount = results.filter(r => r.status === 'OK').length;
_log(`Results: ${okCount}/${results.length} agents succeeded`);
for (const r of results) {
  _log(`  ${r.label}: ${r.status} (${r.elapsed}s, ${r.toolCalls} tool calls)`);
}
_log('');
_log('Reports written:');
if (results.find(r => r.label === 'TestAnalyzer' && r.status === 'OK'))
  _log(`  test-analysis-report.md`);
if (results.find(r => r.label === 'UpstreamDrift' && r.status === 'OK'))
  _log(`  upstream-drift-report.md`);
if (results.find(r => r.label === 'CoverageGap' && r.status === 'OK'))
  _log(`  coverage-gap-report.md`);
_log('');
_log(`Run summary: agent-sdk-last-run.md`);
_log(`Full logs: agent-sdk-activity.log`);
