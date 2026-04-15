#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-FileCopyrightText: Copyright (c) 2026 Jason Perlow. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""
nclawzero test harness — shard-based test result storage and query CLI.

Modeled after MNEMOS memory management. Stores test results as JSON shards,
supports search, filtering, comparison, and trend analysis across runs.

Storage: ~/.nclawzero-harness/
  runs/          — one shard per test run (run_YYYYMMDD_HHMMSS.json)
  exports/       — exported reports

Usage:
  test-harness.py                          # show help
  test-harness.py record [--suite SUITE]   # run tests and record results
  test-harness.py stats                    # summary across all runs
  test-harness.py recent [LIMIT]           # most recent runs
  test-harness.py search QUERY [LIMIT]     # search across test names/errors
  test-harness.py compare RUN1 RUN2        # diff two runs
  test-harness.py trend [DAYS]             # pass rate trend over time
  test-harness.py failures [RUN_ID]        # list failures (latest or specific run)
  test-harness.py flaky [WINDOW]           # detect flaky tests (pass sometimes, fail sometimes)
  test-harness.py get RUN_ID               # full details of a specific run
  test-harness.py export [FORMAT]          # export all runs (json/csv/markdown)
  test-harness.py prune [DAYS]             # delete runs older than N days
"""

import json
import sys
import os
import subprocess
import hashlib
from pathlib import Path
from datetime import datetime, timedelta
from collections import defaultdict

# ── Storage ──────────────────────────────────────────────────────────────────

HARNESS_DIR = Path.home() / ".nclawzero-harness"
RUNS_DIR = HARNESS_DIR / "runs"
EXPORTS_DIR = HARNESS_DIR / "exports"

# ── Data model ───────────────────────────────────────────────────────────────
#
# Each run shard:
# {
#   "id": "run_20260415_103000",
#   "timestamp": "2026-04-15T10:30:00",
#   "suite": "cli" | "plugin" | "all" | "e2e",
#   "duration_seconds": 32.5,
#   "git_ref": "abc1234",
#   "git_branch": "nemoclawzero",
#   "host": "hostname",
#   "node_version": "v22.22.2",
#   "summary": {
#     "total": 1540,
#     "passed": 1530,
#     "failed": 2,
#     "skipped": 8,
#     "pass_rate": 99.87
#   },
#   "tests": [
#     {
#       "name": "credential prompts > exits cleanly when answers are staged through a pipe",
#       "file": "test/credentials.test.ts",
#       "suite": "cli",
#       "status": "pass" | "fail" | "skip",
#       "duration_ms": 2440,
#       "error": null | "AssertionError: expected null to be +0"
#     }
#   ],
#   "failures": [
#     { "name": "...", "file": "...", "error": "..." }
#   ]
# }

RUNS = {}
RUN_INDEX = {}  # suite -> [run_id, ...]


def load_runs():
    """Load all run shards into memory."""
    global RUNS, RUN_INDEX
    RUNS_DIR.mkdir(parents=True, exist_ok=True)

    for shard in sorted(RUNS_DIR.glob("run_*.json")):
        try:
            data = json.loads(shard.read_text())
            run_id = data.get("id", shard.stem)
            RUNS[run_id] = data
            suite = data.get("suite", "unknown")
            RUN_INDEX.setdefault(suite, []).append(run_id)
        except Exception:
            pass  # Skip corrupt shards

    return len(RUNS) > 0


def save_run(run_data):
    """Write a run shard to disk."""
    RUNS_DIR.mkdir(parents=True, exist_ok=True)
    run_id = run_data["id"]
    path = RUNS_DIR / f"{run_id}.json"
    path.write_text(json.dumps(run_data, indent=2))
    RUNS[run_id] = run_data
    suite = run_data.get("suite", "unknown")
    RUN_INDEX.setdefault(suite, []).append(run_id)
    return path


# ── Test runner ──────────────────────────────────────────────────────────────

def run_tests(suite="all"):
    """Execute vitest and capture structured results."""
    repo_root = Path(__file__).resolve().parent.parent

    cmd = ["npx", "vitest", "run", "--reporter=json"]
    if suite == "cli":
        cmd.extend(["--project", "cli"])
    elif suite == "plugin":
        cmd.extend(["--project", "plugin"])

    start = datetime.now()
    result = subprocess.run(
        cmd,
        cwd=str(repo_root),
        capture_output=True,
        text=True,
        timeout=300,
    )
    duration = (datetime.now() - start).total_seconds()

    # Parse vitest JSON output
    try:
        # vitest --reporter=json outputs JSON to stdout
        report = json.loads(result.stdout)
    except json.JSONDecodeError:
        # Fallback: try to extract JSON from mixed output
        for line in result.stdout.splitlines():
            line = line.strip()
            if line.startswith("{"):
                try:
                    report = json.loads(line)
                    break
                except json.JSONDecodeError:
                    continue
        else:
            return None, result.stderr

    # Extract test results
    tests = []
    failures = []
    total = passed = failed = skipped = 0

    for test_file in report.get("testResults", []):
        file_path = test_file.get("name", "")
        # Make path relative to repo root
        if str(repo_root) in file_path:
            file_path = file_path.replace(str(repo_root) + "/", "")

        for assertion in test_file.get("assertionResults", []):
            total += 1
            status_map = {"passed": "pass", "failed": "fail", "skipped": "skip", "pending": "skip"}
            status = status_map.get(assertion.get("status", ""), "unknown")

            test_entry = {
                "name": " > ".join(assertion.get("ancestorTitles", []) + [assertion.get("title", "")]),
                "file": file_path,
                "suite": suite,
                "status": status,
                "duration_ms": assertion.get("duration", 0),
                "error": None,
            }

            if status == "pass":
                passed += 1
            elif status == "fail":
                failed += 1
                msgs = assertion.get("failureMessages", [])
                test_entry["error"] = msgs[0][:500] if msgs else "Unknown error"
                failures.append({
                    "name": test_entry["name"],
                    "file": file_path,
                    "error": test_entry["error"],
                })
            elif status == "skip":
                skipped += 1

            tests.append(test_entry)

    # Git metadata
    git_ref = subprocess.run(
        ["git", "rev-parse", "--short", "HEAD"],
        cwd=str(repo_root), capture_output=True, text=True
    ).stdout.strip()

    git_branch = subprocess.run(
        ["git", "branch", "--show-current"],
        cwd=str(repo_root), capture_output=True, text=True
    ).stdout.strip()

    hostname = os.uname().nodename
    node_ver = subprocess.run(
        ["node", "--version"],
        capture_output=True, text=True
    ).stdout.strip()

    timestamp = datetime.now()
    run_id = f"run_{timestamp.strftime('%Y%m%d_%H%M%S')}"

    run_data = {
        "id": run_id,
        "timestamp": timestamp.isoformat(),
        "suite": suite,
        "duration_seconds": round(duration, 2),
        "git_ref": git_ref,
        "git_branch": git_branch,
        "host": hostname,
        "node_version": node_ver,
        "summary": {
            "total": total,
            "passed": passed,
            "failed": failed,
            "skipped": skipped,
            "pass_rate": round(passed / total * 100, 2) if total > 0 else 0,
        },
        "tests": tests,
        "failures": failures,
    }

    return run_data, None


# ── Commands ─────────────────────────────────────────────────────────────────

def cmd_record(suite="all"):
    """Run tests and record results."""
    print(f"Running {suite} tests...", file=sys.stderr)
    run_data, error = run_tests(suite)
    if error:
        print(json.dumps({"status": "error", "error": error}))
        return

    path = save_run(run_data)
    s = run_data["summary"]
    print(json.dumps({
        "status": "recorded",
        "id": run_data["id"],
        "file": str(path),
        "summary": s,
        "duration_seconds": run_data["duration_seconds"],
    }))


def cmd_stats():
    """Summary statistics across all runs."""
    if not RUNS:
        print(json.dumps({"total_runs": 0}))
        return

    suites = defaultdict(int)
    total_tests = 0
    total_passed = 0
    total_failed = 0

    for run in RUNS.values():
        suites[run.get("suite", "unknown")] += 1
        s = run.get("summary", {})
        total_tests += s.get("total", 0)
        total_passed += s.get("passed", 0)
        total_failed += s.get("failed", 0)

    first_run = min(r["timestamp"] for r in RUNS.values())
    last_run = max(r["timestamp"] for r in RUNS.values())

    print(json.dumps({
        "total_runs": len(RUNS),
        "suites": dict(suites),
        "total_tests_executed": total_tests,
        "total_passed": total_passed,
        "total_failed": total_failed,
        "overall_pass_rate": round(total_passed / total_tests * 100, 2) if total_tests > 0 else 0,
        "first_run": first_run,
        "last_run": last_run,
    }))


def cmd_recent(limit=10):
    """Most recent runs."""
    sorted_runs = sorted(RUNS.values(), key=lambda r: r["timestamp"], reverse=True)[:limit]

    print(json.dumps({
        "count": len(sorted_runs),
        "runs": [{
            "id": r["id"],
            "timestamp": r["timestamp"],
            "suite": r.get("suite", "unknown"),
            "summary": r["summary"],
            "git_ref": r.get("git_ref", ""),
            "duration_seconds": r.get("duration_seconds", 0),
        } for r in sorted_runs],
    }))


def cmd_search(query, limit=20):
    """Search across test names, errors, and file paths."""
    query_lower = query.lower()
    results = []

    for run in RUNS.values():
        for test in run.get("tests", []):
            score = 0
            name = test.get("name", "")
            file_path = test.get("file", "")
            error = test.get("error", "") or ""

            if query_lower in name.lower():
                score += 10
            if query_lower in file_path.lower():
                score += 5
            if query_lower in error.lower():
                score += 8

            if score > 0:
                results.append({
                    "run_id": run["id"],
                    "timestamp": run["timestamp"],
                    "test_name": name,
                    "file": file_path,
                    "status": test.get("status", "unknown"),
                    "error": error[:200] if error else None,
                    "score": score,
                })

    results.sort(key=lambda x: -x["score"])
    print(json.dumps({
        "query": query,
        "count": len(results[:limit]),
        "results": results[:limit],
    }))


def cmd_compare(run_id_1, run_id_2):
    """Diff two runs: new failures, fixed tests, changed tests."""
    r1 = RUNS.get(run_id_1)
    r2 = RUNS.get(run_id_2)

    if not r1:
        print(json.dumps({"error": f"Run not found: {run_id_1}"}))
        return
    if not r2:
        print(json.dumps({"error": f"Run not found: {run_id_2}"}))
        return

    # Build test -> status maps
    def test_map(run):
        return {t["name"]: t["status"] for t in run.get("tests", [])}

    map1 = test_map(r1)
    map2 = test_map(r2)

    all_tests = set(map1.keys()) | set(map2.keys())
    new_failures = []
    fixed = []
    new_tests = []
    removed_tests = []

    for name in all_tests:
        s1 = map1.get(name)
        s2 = map2.get(name)

        if s1 is None and s2 is not None:
            new_tests.append({"name": name, "status": s2})
        elif s1 is not None and s2 is None:
            removed_tests.append({"name": name, "status": s1})
        elif s1 == "pass" and s2 == "fail":
            new_failures.append(name)
        elif s1 == "fail" and s2 == "pass":
            fixed.append(name)

    print(json.dumps({
        "run_1": {"id": run_id_1, "summary": r1["summary"]},
        "run_2": {"id": run_id_2, "summary": r2["summary"]},
        "new_failures": new_failures,
        "fixed": fixed,
        "new_tests": len(new_tests),
        "removed_tests": len(removed_tests),
    }))


def cmd_trend(days=30):
    """Pass rate trend over time."""
    cutoff = datetime.now() - timedelta(days=days)
    daily = defaultdict(lambda: {"passed": 0, "total": 0, "runs": 0})

    for run in RUNS.values():
        ts = datetime.fromisoformat(run["timestamp"])
        if ts < cutoff:
            continue
        day = ts.strftime("%Y-%m-%d")
        s = run.get("summary", {})
        daily[day]["passed"] += s.get("passed", 0)
        daily[day]["total"] += s.get("total", 0)
        daily[day]["runs"] += 1

    trend = []
    for day in sorted(daily.keys()):
        d = daily[day]
        trend.append({
            "date": day,
            "pass_rate": round(d["passed"] / d["total"] * 100, 2) if d["total"] > 0 else 0,
            "total": d["total"],
            "runs": d["runs"],
        })

    print(json.dumps({"days": days, "data_points": len(trend), "trend": trend}))


def cmd_failures(run_id=None):
    """List failures from a specific run or the latest."""
    if run_id:
        run = RUNS.get(run_id)
    else:
        if not RUNS:
            print(json.dumps({"failures": [], "run_id": None}))
            return
        run = max(RUNS.values(), key=lambda r: r["timestamp"])

    if not run:
        print(json.dumps({"error": f"Run not found: {run_id}"}))
        return

    print(json.dumps({
        "run_id": run["id"],
        "timestamp": run["timestamp"],
        "failure_count": len(run.get("failures", [])),
        "failures": run.get("failures", []),
    }))


def cmd_flaky(window=10):
    """Detect flaky tests: tests that pass in some runs and fail in others."""
    # Look at the most recent N runs
    sorted_runs = sorted(RUNS.values(), key=lambda r: r["timestamp"], reverse=True)[:window]

    test_results = defaultdict(list)  # name -> [(run_id, status), ...]

    for run in sorted_runs:
        for test in run.get("tests", []):
            name = test["name"]
            test_results[name].append((run["id"], test["status"]))

    flaky = []
    for name, results in test_results.items():
        statuses = set(status for _, status in results if status in ("pass", "fail"))
        if len(statuses) > 1:  # Both pass and fail
            pass_count = sum(1 for _, s in results if s == "pass")
            fail_count = sum(1 for _, s in results if s == "fail")
            flaky.append({
                "name": name,
                "pass_count": pass_count,
                "fail_count": fail_count,
                "total_runs": len(results),
                "flake_rate": round(fail_count / len(results) * 100, 1),
            })

    flaky.sort(key=lambda x: -x["flake_rate"])
    print(json.dumps({
        "window": window,
        "flaky_count": len(flaky),
        "flaky_tests": flaky,
    }))


def cmd_get(run_id):
    """Full details of a specific run."""
    run = RUNS.get(run_id)
    if not run:
        print(json.dumps({"error": f"Run not found: {run_id}"}))
        return
    print(json.dumps(run))


def cmd_export(format_type="json"):
    """Export all runs."""
    EXPORTS_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    all_runs = sorted(RUNS.values(), key=lambda r: r["timestamp"])

    if format_type == "json":
        path = EXPORTS_DIR / f"harness_export_{timestamp}.json"
        path.write_text(json.dumps(all_runs, indent=2))
    elif format_type == "csv":
        path = EXPORTS_DIR / f"harness_export_{timestamp}.csv"
        lines = ["id,timestamp,suite,total,passed,failed,skipped,pass_rate,git_ref,duration_s"]
        for r in all_runs:
            s = r.get("summary", {})
            lines.append(
                f'{r["id"]},{r["timestamp"]},{r.get("suite","")},{s.get("total",0)},'
                f'{s.get("passed",0)},{s.get("failed",0)},{s.get("skipped",0)},'
                f'{s.get("pass_rate",0)},{r.get("git_ref","")},{r.get("duration_seconds",0)}'
            )
        path.write_text("\n".join(lines))
    elif format_type == "markdown":
        path = EXPORTS_DIR / f"harness_export_{timestamp}.md"
        lines = ["# nclawzero Test Harness Report\n"]
        lines.append(f"Exported: {datetime.now().isoformat()}\n")
        lines.append(f"Total runs: {len(all_runs)}\n")
        lines.append("| Run | Date | Suite | Total | Passed | Failed | Rate | Git |")
        lines.append("|-----|------|-------|-------|--------|--------|------|-----|")
        for r in all_runs:
            s = r.get("summary", {})
            lines.append(
                f'| {r["id"]} | {r["timestamp"][:10]} | {r.get("suite","")} '
                f'| {s.get("total",0)} | {s.get("passed",0)} | {s.get("failed",0)} '
                f'| {s.get("pass_rate",0)}% | {r.get("git_ref","")} |'
            )
        path.write_text("\n".join(lines))
    else:
        print(json.dumps({"error": f"Unknown format: {format_type}"}))
        return

    print(json.dumps({
        "status": "exported",
        "format": format_type,
        "count": len(all_runs),
        "file": str(path),
    }))


def cmd_prune(days=90):
    """Delete runs older than N days."""
    cutoff = datetime.now() - timedelta(days=days)
    pruned = 0

    for shard in RUNS_DIR.glob("run_*.json"):
        try:
            data = json.loads(shard.read_text())
            ts = datetime.fromisoformat(data["timestamp"])
            if ts < cutoff:
                shard.unlink()
                pruned += 1
        except Exception:
            pass

    print(json.dumps({"pruned": pruned, "cutoff_days": days}))


# ── Help ─────────────────────────────────────────────────────────────────────

HELP = """
nclawzero test harness — shard-based test result storage and query CLI

COMMANDS:
  record [--suite cli|plugin|all]  Run tests and record results
  stats                            Summary across all runs
  recent [LIMIT]                   Most recent runs (default: 10)
  search QUERY [LIMIT]             Search test names, errors, file paths
  compare RUN1 RUN2                Diff two runs (new failures, fixes)
  trend [DAYS]                     Pass rate trend over time (default: 30)
  failures [RUN_ID]                List failures (latest run if omitted)
  flaky [WINDOW]                   Detect flaky tests across recent runs (default: 10)
  get RUN_ID                       Full details of a specific run
  export [json|csv|markdown]       Export all runs (default: json)
  prune [DAYS]                     Delete runs older than N days (default: 90)

STORAGE:
  ~/.nclawzero-harness/runs/       One JSON shard per test run
  ~/.nclawzero-harness/exports/    Exported reports

EXAMPLES:
  test-harness.py record                     # Run all tests, save results
  test-harness.py record --suite plugin      # Run plugin tests only
  test-harness.py recent 5                   # Last 5 runs
  test-harness.py failures                   # Failures from latest run
  test-harness.py search "credential" 10     # Find tests matching "credential"
  test-harness.py flaky 20                   # Flaky tests across last 20 runs
  test-harness.py compare run_20260415_1030 run_20260415_1145
  test-harness.py trend 7                    # Pass rate trend, last 7 days
  test-harness.py export markdown            # Export report
"""


# ── Main ─────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] in ("help", "--help", "-h"):
        print(HELP)
        sys.exit(0)

    load_runs()
    cmd = sys.argv[1]

    if cmd == "record":
        suite = "all"
        if "--suite" in sys.argv:
            idx = sys.argv.index("--suite")
            if idx + 1 < len(sys.argv):
                suite = sys.argv[idx + 1]
        cmd_record(suite)
    elif cmd == "stats":
        cmd_stats()
    elif cmd == "recent":
        limit = int(sys.argv[2]) if len(sys.argv) > 2 else 10
        cmd_recent(limit)
    elif cmd == "search":
        if len(sys.argv) < 3:
            print(json.dumps({"error": "search requires a query"}))
            sys.exit(1)
        limit = int(sys.argv[3]) if len(sys.argv) > 3 else 20
        cmd_search(sys.argv[2], limit)
    elif cmd == "compare":
        if len(sys.argv) < 4:
            print(json.dumps({"error": "compare requires two run IDs"}))
            sys.exit(1)
        cmd_compare(sys.argv[2], sys.argv[3])
    elif cmd == "trend":
        days = int(sys.argv[2]) if len(sys.argv) > 2 else 30
        cmd_trend(days)
    elif cmd == "failures":
        run_id = sys.argv[2] if len(sys.argv) > 2 else None
        cmd_failures(run_id)
    elif cmd == "flaky":
        window = int(sys.argv[2]) if len(sys.argv) > 2 else 10
        cmd_flaky(window)
    elif cmd == "get":
        if len(sys.argv) < 3:
            print(json.dumps({"error": "get requires a run ID"}))
            sys.exit(1)
        cmd_get(sys.argv[2])
    elif cmd == "export":
        fmt = sys.argv[2] if len(sys.argv) > 2 else "json"
        cmd_export(fmt)
    elif cmd == "prune":
        days = int(sys.argv[2]) if len(sys.argv) > 2 else 90
        cmd_prune(days)
    else:
        print(json.dumps({"error": f"Unknown command: {cmd}"}))
        sys.exit(1)
