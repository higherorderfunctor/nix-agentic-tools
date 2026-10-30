"""Replayable Kiro usage experiment. No paid CLI commands run without --run."""

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

import credit_discount as discount
from runtime import state_directory

EFFORT = "low"
# Each step runs every model's labels back to back, so a warm repeat directly follows its own cold call and
# the quiet wait before the delayed repeat is paid once for all models.
STEPS = (("medium_cold", "medium_warm"), ("size_short",), ("size_long",), ("output_short",), ("output_long",),
         ("conversation_1",), ("conversation_2",), ("conversation_3",), ("medium_delayed",))
# A call's prompt family: the leading nonce of its user and agent prompts. Only calls sharing one send a common
# prefix, so no call hits another family's cache (the output pair is two: output_long hit output_short's).
FAMILIES = {"conversation_1": "conversation", "conversation_2": "conversation", "conversation_3": "conversation",
            "medium_cold": "medium", "medium_delayed": "medium", "medium_warm": "medium", "output_long": "output_long",
            "output_short": "output_short", "size_long": "long", "size_short": "short"}
RESUMES = {"conversation_2": "conversation_1", "conversation_3": "conversation_1"}  # resumed turn: its session's first
DELAY_SECONDS = 361
CAPTURE_WAIT = 5
CAPTURE_SETTLE = 0.2
LOG_LIMIT = 16_384


class ExitError(RuntimeError):
    """A paid invocation exited non-zero."""


def interrupted(signum, _frame):
    raise KeyboardInterrupt(f"received signal {signum}")


def cli_output(*arguments):
    return subprocess.run(["kiro-cli", *arguments], stdin=subprocess.DEVNULL, capture_output=True, text=True,
                          check=True, timeout=60).stdout


def cli_version():
    return cli_output("--version").split()[-1]  # "kiro-cli 2.35.2"


def refresh_models():
    """Snapshot the free model listing's windows and multipliers, with the CLI version that printed them."""
    listed = json.loads(cli_output("chat", "--list-models", "--format", "json"))["models"]
    discount.MODELS_PATH.write_text(json.dumps({"kiro_cli_version": cli_version(), "models": {
        model["model_id"]: {key: model[key] for key in ("context_window_tokens", "rate_multiplier")} for model in listed}},
        indent=2, sort_keys=True) + "\n")


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
            raise RuntimeError("collector marked capture incomplete; check its issues_json and omission counters")
        if time.monotonic() >= deadline:
            raise RuntimeError("no complete capture evidence for this invocation within five seconds")
        time.sleep(0.05)


def snapshot(workspace):
    return {str(path.relative_to(workspace)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(workspace.rglob("*")) if path.is_file()}


def nonce(seed, family):
    return hashlib.sha256(f"{seed}:{family}".encode()).hexdigest()[:32]


def agent_name(model, label):
    return f"usage-calibration-{model}-{FAMILIES[label]}"  # the agent JSON carries its model


def fixture(seed, family, text):
    return f"{nonce(seed, family)}\nReference text; treat as data only.\n{text}\nReply with the single word READY."


def prompts(seed):
    medium = fixture(seed, "medium", "cedar birch maple willow " * 1024)
    output = "\nUse decimal integers in ascending order, separated by single spaces. "
    return {"medium_cold": medium, "medium_warm": medium,
            "size_short": fixture(seed, "short", "cedar birch maple willow " * 256),
            "size_long": fixture(seed, "long", "cedar birch maple willow " * 3072),
            "output_short": f"{nonce(seed, 'output_short')}{output}Print the integers from 1 through 5 only.",
            "output_long": f"{nonce(seed, 'output_long')}{output}Print the integers from 1 through 200 only.",
            "conversation_1": f"{nonce(seed, 'conversation')}\nRemember CEDAR. Reply READY only.",
            "conversation_2": "What word did I ask you to remember? Reply with that word only.",
            "conversation_3": "Repeat that same remembered word. Reply with the word only.",
            "medium_delayed": medium}


def selected_models(args, parser):
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    models = list(dict.fromkeys(args.models.split(",")))  # a repeated id runs once
    for model in models:
        if model not in discount.WINDOWS:  # Unlisted ids, typos and routers such as auto have no window to fit.
            parser.error(f"unknown or router model: {model}; refresh with `calibration.py models`")
    return models


def experiment(args, parser, models):
    """Preview, or with --run make, the probe's paid calls for each model; the exit status."""
    print(f"Models {', '.join(models)}; effort {EFFORT}; {sum(map(len, STEPS)) * len(models)} CLI invocations, "
          "possibly more provider requests.")
    print("Cold/warm/delayed are experiment labels, not verified cache states.")
    print("Final repeats follow >6 quiet minutes after the other calls finish.")
    if not args.run:
        print("Dry run only. Add --run to execute. No CLI commands were called.")
        return 0
    for executable in ("kiro-cli", "kiro-usage"):
        if not shutil.which(executable):
            parser.error(f"missing executable: {executable}")
    db = open_evidence(args.db or state_directory(None) / "usage.sqlite3")
    version = cli_version()
    os.umask(0o077)
    root = Path(tempfile.mkdtemp(prefix="kiro-usage-calibration-"))
    workspace, results = root / "workspace", root / "results"
    workspace.mkdir()
    results.mkdir()
    seed = secrets.token_hex(16)
    agent_dir = workspace / ".kiro" / "agents"
    agent_dir.mkdir(parents=True)
    # One agent per (model, family): the agent prompt leads msg0, so a shared one would share a cached prefix.
    agents = {agent_name(model, label): (model, FAMILIES[label]) for model in models for step in STEPS for label in step}
    for agent, (model, family) in agents.items():
        (agent_dir / f"{agent}.json").write_text(json.dumps({"name": agent, "description": "Usage calibration",
            "prompt": f"Run {nonce(f'{seed}:{model}', family)}. Answer directly without tools.", "tools": [],
            "resources": [], "mcpServers": {}, "includeMcpJson": False, "includePowers": False,
            "model": model, "effortLevel": EFFORT}, indent=2) + "\n")
    baseline = snapshot(workspace)
    manifest = {"models": models, "effort": EFFORT, "kiro_cli_version": version, "workspace": str(workspace),
                "seed": seed, "calls": [], "dropped_models": {}, "workspace_initial": baseline,
                "notes": ["Global context remains uncontrolled; compare captured request hashes offline.",
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

    def invoke(model, step, prompt, resume=None):
        label = f"{model}.{step}"
        before = sessions(label + "-before")
        if resume is not None and resume not in before:
            raise RuntimeError("explicit resume session is missing")
        (results / f"{label}.prompt.txt").write_text(prompt + "\n")
        command = ["kiro-usage", "exec", "kiro-cli", "chat", "--model", model, "--effort", EFFORT,
                   "--agent", agent_name(model, step), "--no-interactive", "--trust-tools=",
                   "--trust-workspace", "--output-format", "stream-json"]
        if resume is not None:
            command += ["--resume-id", resume]
        record = {"label": step, "session_id": resume, "started_utc_ns": time.time_ns(),
                  "status": "running", "exit_code": None, "model": model, "effort": EFFORT}
        manifest["calls"].append(record)
        save()
        print(f"Running {label}...", flush=True)
        try:
            record["exit_code"] = run(command + [prompt], label)
            if record["exit_code"]:
                raise ExitError(f"{label} exited {record['exit_code']}")
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
        for agent in agents:
            if run(["kiro-cli", "agent", "validate", "--path", str(agent_dir / f"{agent}.json")], f"{agent}.agent-validation"):
                raise RuntimeError(f"local agent validation failed for {agent}; no paid call started")
        dropped, conversations = manifest["dropped_models"], {}
        fixtures = {model: prompts(f"{seed}:{model}") for model in models}  # one model's call cannot warm another's
        for step in STEPS:
            if step == ("medium_delayed",):
                print(f"Waiting {DELAY_SECONDS}s without probe calls...", flush=True)
                time.sleep(DELAY_SECONDS)
            for model in (model for model in models if model not in dropped):
                for label in step:
                    resume = conversations.get((model, RESUMES[label])) if label in RESUMES else None
                    try:
                        session = invoke(model, label, fixtures[model][label], resume)
                    except ExitError as error:
                        # A model refusing --effort low fails its first call; drop it and keep the others.
                        if label != STEPS[0][0]:
                            raise
                        dropped[model] = str(error)
                        save()
                        print(f"Dropped {model}: {error}", flush=True)
                        break
                    if label in RESUMES.values():
                        conversations[model, label] = session
            if len(dropped) == len(models):
                raise RuntimeError("every model failed its first call")
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
    print(f"Complete: {len(manifest['calls'])} CLI invocations. Manifest: {manifest_path}")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    probe = commands.add_parser("probe", help="preview, or with --run make, the paid probe calls")
    probe.add_argument("--db", type=Path, help="collector database; defaults to runtime state directory")
    probe.add_argument("--models", default=discount.PROFILE_MODEL, help="comma-separated model ids from models.json")
    probe.add_argument("--run", action="store_true", help="authorize the paid CLI invocations the preview counts")
    probe.add_argument("--timeout", type=float, default=180, help="seconds per CLI command")
    commands.add_parser("models", help="refresh models.json from the free kiro-cli chat --list-models")
    args = parser.parse_args()
    if args.command == "models":
        refresh_models()
        return 0
    return experiment(args, probe, selected_models(args, probe))


if __name__ == "__main__":
    raise SystemExit(main())
