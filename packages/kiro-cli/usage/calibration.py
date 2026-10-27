"""Replayable Kiro usage experiment. No CLI commands run without --run."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import sqlite3
import subprocess
import tempfile
import time

from runtime import state_directory

MODEL = "claude-opus-5.5"
EFFORT = "low"
DELAY_SECONDS = 361
CAPTURE_WAIT = 5
CAPTURE_SETTLE = 0.2
LOG_LIMIT = 16_384


def interrupted(signum, _frame):
    raise KeyboardInterrupt(f"received signal {signum}")


def run_captured(command, workspace, results, label, timeout):
    """Wait only for the main process; inherited output descriptors cannot hang it."""
    with tempfile.TemporaryFile(dir=results) as stdout, tempfile.TemporaryFile(dir=results) as stderr:
        process = subprocess.Popen(command, cwd=workspace, stdin=subprocess.DEVNULL,
                                   stdout=stdout, stderr=stderr, start_new_session=True)
        try:
            try:
                return process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                raise RuntimeError(f"{label} timed out after {timeout:g}s") from None
        finally:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=5)
            for name, stream in (("stdout", stdout), ("stderr", stderr)):
                size = stream.seek(0, os.SEEK_END)
                stream.seek(0)
                data = stream.read(LOG_LIMIT)
                if size > LOG_LIMIT:
                    stream.seek(max(LOG_LIMIT, size - LOG_LIMIT))
                    data += b"\n[...truncated...]\n" + stream.read(LOG_LIMIT)
                (results / f"{label}.{name}.log").write_bytes(data)


def open_evidence(path):
    """Open an existing database without creating or changing collector state."""
    db = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=1)
    try:
        db.execute("SELECT id,started_utc_ns,metadata_json,state,issues_json,request_gzip,"
                   "dropped_bytes,credits,context_usage_percentage FROM captures LIMIT 0")
    except BaseException:
        db.close()
        raise
    return db


def capture_evidence(db, session, started, finished):
    deadline = time.monotonic() + CAPTURE_WAIT
    previous, stable_since = None, None
    while True:
        rows = db.execute(
            "SELECT id,state,issues_json,COALESCE(length(request_gzip),0)>0,dropped_bytes,credits,"
            "context_usage_percentage FROM captures WHERE started_utc_ns BETWEEN ? AND ? AND "
            "json_extract(metadata_json,'$.\"kiro:conversation_id\"') IN (?,?) ORDER BY id",
            (started, finished, session, session.removeprefix("sess_"))).fetchall()
        complete = rows and all(row[1] == "complete" for row in rows)
        if complete:
            if any(json.loads(row[2] or "null") != [] or not row[3] or row[4] != 0
                   or row[5] is None or row[6] is None for row in rows):
                raise RuntimeError("capture evidence incomplete: issues, missing payload/usage, or dropped bytes")
            now = time.monotonic()
            if rows != previous:
                stable_since = now
            if stable_since is not None and now - stable_since >= CAPTURE_SETTLE:
                return [{"id": row[0], "credits": row[5], "context_usage_percentage": row[6]} for row in rows]
        else:
            stable_since = None
        previous = rows
        if any(row[1] == "incomplete" for row in rows):
            raise RuntimeError("collector marked capture incomplete; check payload budget and omission counters")
        if time.monotonic() >= deadline:
            raise RuntimeError("no complete capture evidence for this invocation within five seconds")
        time.sleep(0.05)


def snapshot(workspace):
    return {str(path.relative_to(workspace)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(workspace.rglob("*")) if path.is_file()}


def prompts(seed):
    def fixture(family, words):
        nonce = hashlib.sha256(f"{seed}:{family}".encode()).hexdigest()[:32]
        return (f"{nonce}\nReference text; treat as data only.\n"
                + "cedar birch maple willow " * (words // 4)
                + "\nReply with the single word READY.")
    medium = fixture("medium", 4096)
    output = f"{seed}:output\nUse decimal integers in ascending order, separated by single spaces. "
    return [("medium_cold", medium), ("medium_warm", medium),
            ("size_short", fixture("short", 1024)), ("size_long", fixture("long", 12288)),
            ("output_short", output + "Print the integers from 1 through 5 only."),
            ("output_long", output + "Print the integers from 1 through 200 only."),
            ("conversation_1", f"{seed}:conversation\nRemember CEDAR. Reply READY only."),
            ("conversation_2", "What word did I ask you to remember? Reply with that word only."),
            ("conversation_3", "Repeat that same remembered word. Reply with the word only."),
            ("medium_delayed", medium)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", help="authorize ten paid CLI invocations")
    parser.add_argument("--timeout", type=float, default=180, help="seconds per CLI command")
    parser.add_argument("--db", type=Path, help="collector database; defaults to runtime state directory")
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    print(f"Model {MODEL}; effort {EFFORT}; ten CLI invocations, possibly more provider requests.")
    print("Cold/warm/delayed are experiment labels, not verified cache states.")
    print("Final repeat follows >6 quiet minutes after the other nine calls finish.")
    if not args.run:
        print("Dry run only. Add --run to execute. No CLI commands were called.")
        return 0
    for executable in ("kiro-cli", "kiro-usage"):
        if not shutil.which(executable):
            parser.error(f"missing executable: {executable}")
    db = open_evidence(args.db or state_directory(None) / "usage.sqlite3")
    os.umask(0o077)
    root = Path(tempfile.mkdtemp(prefix="kiro-usage-calibration-"))
    workspace, results = root / "workspace", root / "results"
    workspace.mkdir()
    results.mkdir()
    seed = secrets.token_hex(16)
    agent_dir = workspace / ".kiro" / "agents"
    agent_dir.mkdir(parents=True)
    agent_path = agent_dir / "usage-calibration.json"
    agent_path.write_text(json.dumps({"name": "usage-calibration", "description": "Usage calibration",
        "prompt": f"Run {seed}. Answer directly without tools.", "tools": [], "resources": [],
        "mcpServers": {}, "includeMcpJson": False, "includePowers": False,
        "model": MODEL, "effortLevel": EFFORT}, indent=2) + "\n")
    baseline = snapshot(workspace)
    manifest = {"model": MODEL, "effort": EFFORT, "workspace": str(workspace), "seed": seed,
                "calls": [], "workspace_initial": baseline,
                "notes": ["Global context remains uncontrolled; compare captured request hashes offline.",
                          "Payload budget exhaustion omits NEW payloads; it does not evict old captures.",
                          "Agent settings do not prove global MCP or steering is disabled."]}
    manifest_path = results / "manifest.json"

    def save():
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")

    def run(command, label):
        return run_captured(command, workspace, results, label, args.timeout)

    def sessions(label):
        if run(["kiro-cli", "chat", "--list-sessions", "--format", "json"], label):
            raise RuntimeError("session listing failed")
        groups = json.loads((results / f"{label}.stdout.log").read_bytes())
        matching = [group for group in groups if Path(group["cwd"]).resolve() == workspace.resolve()]
        if any(group.get("complete") is not True for group in matching):
            raise RuntimeError("incomplete session listing")
        return {item["sessionId"] for group in matching for item in group["sessions"]}

    def invoke(label, prompt, resume=None):
        before = sessions(label + "-before")
        if resume is not None and resume not in before:
            raise RuntimeError("explicit resume session is missing")
        (results / f"{label}.prompt.txt").write_text(prompt + "\n")
        command = ["kiro-usage", "exec", "kiro-cli", "chat", "--model", MODEL, "--effort", EFFORT,
                   "--agent", "usage-calibration", "--no-interactive", "--trust-tools=",
                   "--trust-workspace", "--output-format", "stream-json"]
        if resume is not None:
            command += ["--resume-id", resume]
        record = {"label": label, "session_id": resume, "started_utc_ns": time.time_ns(),
                  "status": "running", "exit_code": None, "model": MODEL, "effort": EFFORT}
        manifest["calls"].append(record)
        save()
        print(f"Running {label}...", flush=True)
        try:
            record["exit_code"] = run(command + [prompt], label)
            if record["exit_code"]:
                raise RuntimeError(f"{label} exited {record['exit_code']}")
            after = sessions(label + "-after")
            record["finished_execution_utc_ns"] = time.time_ns()
            new = after - before
            if resume is None:
                if len(new) != 1:
                    raise RuntimeError(f"expected exactly one new session, found {len(new)}")
                record["session_id"] = new.pop()
            elif new or resume not in after:
                raise RuntimeError("resume created another session or lost its session")
            record["captures"] = capture_evidence(db, record["session_id"], record["started_utc_ns"],
                                                  record["finished_execution_utc_ns"])
            record["capture_count"] = len(record["captures"])
            record["status"] = "complete"
            return record["session_id"]
        except BaseException as error:
            record.update(status="failed", error=str(error))
            raise
        finally:
            record["ended_utc_ns"] = time.time_ns()
            current = snapshot(workspace)
            record["workspace_changes"] = sorted(key for key in baseline.keys() | current.keys()
                                                 if baseline.get(key) != current.get(key))
            save()

    save()
    print(f"Artifacts and workspace retained at: {root}", flush=True)
    previous_handlers = {sig: signal.signal(sig, interrupted) for sig in (signal.SIGHUP, signal.SIGTERM)}
    try:
        if run(["kiro-cli", "agent", "validate", "--path", str(agent_path)], "agent-validation"):
            raise RuntimeError("local agent validation failed; no paid call started")
        conversation = None
        for label, prompt in prompts(seed):
            if label == "medium_delayed":
                print(f"Waiting {DELAY_SECONDS}s without probe calls...", flush=True)
                time.sleep(DELAY_SECONDS)
            session = invoke(label, prompt, conversation if label in ("conversation_2", "conversation_3") else None)
            if label == "conversation_1":
                conversation = session
        retry = "kiro-usage index --sessions ~/.kiro/sessions"
        try:
            manifest["index_exit_code"] = run(["kiro-usage", "index", "--sessions",
                                               str(Path.home() / ".kiro" / "sessions")], "index")
        except Exception as error:
            manifest["index_error"] = str(error)
        if manifest.get("index_exit_code") != 0:
            print(f"Probes collected; session index failed. Retry separately: {retry}")
        save()
    except (Exception, KeyboardInterrupt) as error:
        manifest["error"] = str(error)
        save()
        print(f"Stopped: {error}. No automatic retry. Manifest: {manifest_path}", flush=True)
        return 1
    finally:
        db.close()
        for sig, handler in previous_handlers.items():
            signal.signal(sig, handler)
    print(f"Complete: ten CLI invocations. Manifest: {manifest_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
