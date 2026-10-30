"""Replayable Kiro usage experiment and its rate fit. No paid CLI commands run without --run."""

import argparse
from collections import namedtuple
from datetime import date
import hashlib
import json
import math
import os
from pathlib import Path
import secrets
import shutil
import signal
import sqlite3
import statistics
import subprocess
import tempfile
import time

import credit_discount as discount
from display import table
from runtime import state_directory

EFFORT = "low"
# Each step runs every model's labels back to back, so a warm repeat directly follows its own cold call and
# the quiet wait before the delayed repeat is paid once for all models.
STEPS = (("medium_cold", "medium_warm"), ("size_short",), ("size_long",), ("output_short",), ("output_long",),
         ("conversation_1",), ("conversation_2",), ("conversation_3",), ("medium_delayed",))
# validate's holdout: prompts the fit never used, each at a cache state fixed by design.
HOLDOUT_STEPS = (("holdout_small_cold", "holdout_small_warm"), ("holdout_large_cold", "holdout_large_warm"),
                 ("holdout_prose_out",))
HOLDOUT_LABELS = tuple(label for step in HOLDOUT_STEPS for label in step)
# probe --sweep's cold prose calls, before medium_delayed; 24000 words passed Linux's 128 KiB limit on one argument.
SWEEP_STEPS = tuple((f"sweep_{words:05}",) for words in (500, 1000, 2000, 3000, 4000, 6000, 8000, 12000, 16000))
# A call's prompt family: the leading nonce of its user and agent prompts. Only calls sharing one send a common
# prefix, so no call hits another family's cache (the output pair is two: output_long hit output_short's).
FAMILIES = {"conversation_1": "conversation", "conversation_2": "conversation", "conversation_3": "conversation",
            "holdout_large_cold": "holdout_large", "holdout_large_warm": "holdout_large",
            "holdout_prose_out": "holdout_prose", "holdout_small_cold": "holdout_small",
            "holdout_small_warm": "holdout_small", "medium_cold": "medium", "medium_delayed": "medium", "medium_warm": "medium",
            "output_long": "output_long", "output_short": "output_short", "size_long": "long", "size_short": "short",
            **{label: label for (label,) in SWEEP_STEPS}}
RESUMES = {"conversation_2": "conversation_1", "conversation_3": "conversation_1"}  # resumed turn: its session's first
COLD_LABELS = ("medium_cold", "size_long", "size_short")  # full misses; probe --sweep's sweep_* calls replace them
# Each repeat after its cold call; validate's holdout pairs join when a pooled manifest has them.
HIT_PAIRS = (("holdout_large_cold", "holdout_large_warm"), ("holdout_small_cold", "holdout_small_warm"),
             ("medium_cold", "medium_delayed"), ("medium_cold", "medium_warm"))
# A repeat is a hit only below this share of its cold call's credits: hits billed 10-53%, an expired one 97%.
HIT_LIMIT = .8
OUTPUT_LABELS = ("output_long", "output_short")
# The miss line may miss a cold call by this share of its credits; claude-haiku-5.5's medium_cold billed 14% over.
RESIDUAL_LIMIT = .05
# Above this credit_error, credits cannot price one prose reply (claude-haiku-5.5's read 9.2-10.8 chars per token).
CHARS_ERROR_LIMIT = .02
RATE_NAMES = ("fixed_per_call", "hit_input", "miss_input", "output")
TOLERANCE = (.02, .0005)  # a designed call passes within the larger of this share of its credits and these credits
DELAY_SECONDS = 361
CAPTURE_WAIT = 5
CAPTURE_SETTLE = 0.2
LOG_LIMIT = 16_384


Call = namedtuple("Call", "input output credits cached chars")  # fit_calls' tokens; cached is estimate()'s split


class ExitError(RuntimeError):
    """A paid invocation exited non-zero."""


def interrupted(signum, _frame):
    raise KeyboardInterrupt(f"received signal {signum}")


def cli_output(*arguments):
    return subprocess.run(["kiro-cli", *arguments], stdin=subprocess.DEVNULL, capture_output=True, text=True,
                          check=True, timeout=60).stdout


def cli_version():
    return cli_output("--version").split()[-1]  # "kiro-cli 2.35.2"


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def refresh_models():
    """Snapshot the free model listing's windows and multipliers, with the CLI version that printed them."""
    listed = json.loads(cli_output("chat", "--list-models", "--format", "json"))["models"]
    write_json(discount.MODELS_PATH, {"kiro_cli_version": cli_version(), "models": {
        model["model_id"]: {key: model[key] for key in ("context_window_tokens", "rate_multiplier")} for model in listed}})


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
                   "dropped_bytes,credits,context_usage_percentage,input_tokens,output_tokens,summary_json FROM captures LIMIT 0")
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
            "medium_delayed": medium,
            **{label: fixture(seed, label, prose(int(label.removeprefix("sweep_")), start))
               for start, (label,) in enumerate(SWEEP_STEPS)}}


def prose(words, start):
    """Eight-word sentences over a word list unlike the cedar fixtures', rotated by start so each fixture's text is
    its own."""
    vocabulary = ("amber", "harbor", "lantern", "meadow", "orchard", "quietly", "river", "signal", "summit",
                  "thunder", "travelers", "valley", "winter")
    return " ".join(" ".join(vocabulary[(start + sentence + word) % len(vocabulary)] for word in range(8)).capitalize()
                    + "." for sentence in range(words // 8))


def holdout_prompts(seed):
    small, large = fixture(seed, "holdout_small", prose(2000, 0)), fixture(seed, "holdout_large", prose(9000, 3))
    return {"holdout_large_cold": large, "holdout_large_warm": large,
            "holdout_prose_out": f"{nonce(seed, 'holdout_prose')}\nWrite about 150 words of plain prose about a river "
                                 "town at dawn. No lists, headings, code or tools.",
            "holdout_small_cold": small, "holdout_small_warm": small}


def fit_calls(db, manifest, ratio=None):
    """One manifest's {model: {label: Call}} for complete one-capture calls, on query.call_counters' basis: exact
    counters where reported, else estimate()'s split, so fitted rates price what estimate() later sees. ratio
    overrides rates.json's chars_per_token, so a fit never reads the entry it replaces."""
    calls = {}
    for call in manifest["calls"]:
        if call.get("status") != "complete" or call.get("capture_count") != 1:
            continue
        row = db.execute("SELECT credits,context_usage_percentage,json_extract(summary_json,'$.output_text_chars')"
                         "+coalesce(json_extract(summary_json,'$.tool_chars'),0)"
                         "+coalesce(json_extract(summary_json,'$.reasoning_chars'),0),output_tokens,input_tokens FROM captures WHERE id=?",
                         (call["captures"][0]["id"],)).fetchone()
        # row is None for a capture absent from this --db.
        tokens = row and discount.estimate(call["model"], row[1], row[0], row[2], row[3], row[4], ratio)
        # The collector stores 0-credit captures; they price nothing and would divide every residual by zero.
        if tokens and tokens["output_tokens"] is not None and discount.finite(row[0]) and row[0] > 0:
            calls.setdefault(call["model"], {})[call["label"]] = Call(tokens["input_tokens"], tokens["output_tokens"],
                                                                      row[0], tokens["cache_read_tokens"], row[2])
    return calls


def fit_model(model, runs, version, effort):
    """Output rate from the output pairs, miss line by least squares over the cold calls (the sweep's when it has
    three), hit rate from each repeat against its cold call. runs holds one {label: Call} per manifest, so a label
    repeated across manifests stays distinct.

    Each probe family leads its agent and user prompt with its own nonce, so cold calls bill full misses.
    """
    pairs = [(run["output_short"], run["output_long"]) for run in runs if all(label in run for label in OUTPUT_LABELS)]
    sweep = [call for run in runs for label, call in run.items() if label.startswith("sweep_")]
    # Three sweep calls draw the line alone (claude-haiku-5.5's probe cold calls disagree); fewer join the probe's.
    colds = sweep if len(sweep) >= 3 else sweep + [call for run in runs for label, call in run.items() if label in COLD_LABELS]
    if not pairs or len(colds) < 3:  # two cold calls always fit a line exactly, so a third checks it
        return {"refused": f"needs {', '.join(OUTPUT_LABELS)} and three cold calls ({', '.join(COLD_LABELS)} or sweep_*)"}
    if len({call.input for call in colds}) < 2:  # e.g. three sweep calls of one size: no slope to regress
        return {"refused": "cold calls share one input size"}
    # The pair's prompts differ only in their nonces and final integer, so its total-token difference (context %,
    # which counts output) is the output-token difference. Splitting that total into input and output first would
    # read input from chars / chars_per_token, which counts too few of the digit reply by ~150 tokens; the nonces move
    # input by a few at most. A model replying identically to both prompts has no token difference to divide by.
    deltas = [(wide.credits - short.credits, wide.input + wide.output - short.input - short.output)
              for short, wide in pairs]
    if not all(tokens for _, tokens in deltas):
        return {"refused": "output pair has no token difference"}
    # A long reply billed no more than its short one rode a cached prefix: claude-haiku-5.5's output_long of
    # 2026-10-29 hit the one output_short had just written and billed 0.0041 credits against 0.0067.
    if any(credits / tokens <= 0 for credits, tokens in deltas):
        return {"refused": "output pair implies a non-positive output rate"}
    output = statistics.fmean(credits / tokens for credits, tokens in deltas)
    miss, fixed = statistics.linear_regression([call.input for call in colds],
                                               [call.credits - output * call.output for call in colds])
    # validate's holdout cold calls only check the line: claude-haiku-5.5's holdout_small_cold billed 14% above it.
    checked = [run[label] for run in runs for label in ("holdout_large_cold", "holdout_small_cold") if label in run]
    rates = {"fixed_per_call": fixed, "miss_input": miss, "output": output}
    hits = [(repeat, run[cold], run[repeat]) for run in runs for cold, repeat in HIT_PAIRS
            if cold in run and repeat in run and run[repeat].credits < HIT_LIMIT * run[cold].credits]
    inputs = [hit.input for *_, hit in hits]
    if inputs and min(inputs) <= max(inputs) / 2:
        # Hits at two sizes (validate's small and large holdouts) draw their own line. Its intercept and the cold
        # line's are fixed - hit * K and fixed - miss * K for K unbilled tokens, so they solve for both.
        slope, warm = statistics.linear_regression(inputs, [call.credits - output * call.output for *_, call in hits])
        unbilled = (warm - fixed) / (miss - slope)
        smallest = min(call.input for run in runs for call in run.values())  # K is counted in every call's input
        if abs(unbilled) < smallest / 100:
            # Whole-token output rounding on exact data leaves claude-opus-5.5 and claude-sonnet-5.5 a K of 15.3
            # against ~7,000 input tokens, and data with no offset a K of -0: artifacts, not an offset, so the cold
            # line's intercept stands.
            rates.update(hit_input=slope)
        elif not 0 <= unbilled <= smallest:  # no K explains a warm intercept below the cold one, or past every input
            return {"refused": f"unbilled tokens {unbilled:.0f} outside 0 to the smallest call's {smallest}"}
        else:
            rates.update(fixed_per_call=fixed + miss * unbilled, hit_input=slope, unbilled_tokens=unbilled)
    elif hits:  # each repeat on its own counters, which can differ from its cold call's (claude-haiku-5.5's output)
        rates["hit_input"] = statistics.fmean((hit.credits - fixed - output * hit.output) / hit.input for *_, hit in hits)
    # The share of its credits the miss line misses each cold call by, and each hit's price at its whole input.
    off = lambda call: abs(call.credits - fixed - miss * call.input - output * call.output) / call.credits
    residual = max(map(off, colds))
    errors = [*map(off, colds + checked),
              *(abs(hit.credits - discount.price(rates, hit.input, hit.output, hit.input)) / hit.credits for *_, hit in hits)]
    rates["credit_error"] = math.sqrt(statistics.fmean(error * error for error in errors))  # estimate()'s ± per call
    reference, multipliers = discount.RATES[discount.PROFILE_MODEL], discount.FACTS["models"]
    share = multipliers[model]["rate_multiplier"] / multipliers[discount.PROFILE_MODEL]["rate_multiplier"]
    result = {"provenance": {"calls": len(errors) + 2 * len(pairs), "date": date.today().isoformat(), "effort": effort,
                             "kiro_cli_version": version, "max_residual": max(map(off, colds + checked))},
              "rates": rates, "ratios": {name: rates[name] / (reference[name] * share) for name in RATE_NAMES if name in rates}}
    if residual > RESIDUAL_LIMIT:
        result["refused"] = "cold calls disagree"
    elif not any(label == "medium_warm" for label, *_ in hits):
        result["refused"] = "no hit observed"
    return result


def fit_pool(db, manifests, model, version, effort):
    """fit_model at CHARS_PER_TOKEN, then once more at the mean chars_per_token of the pool's holdout_prose_out replies,
    which the entry carries, so estimate() reads output at the ratio its rates were fitted at.

    One refit suffices: the ratio only moves the 1-6 char replies of the fitted calls by a token, so their rates and
    credit_error barely move. Past CHARS_ERROR_LIMIT the credits cannot price one reply, so no ratio is fitted."""
    runs = lambda ratio: [fit_calls(db, manifest, ratio).get(model, {}) for manifest in manifests]
    pool = runs(discount.CHARS_PER_TOKEN)
    result = fit_model(model, pool, version, effort)
    if "refused" in result or result["rates"]["credit_error"] > CHARS_ERROR_LIMIT:
        return result
    ratios = [ratio for ratio in (prose_chars_per_token(result["rates"], run["holdout_prose_out"])
                                  for run in pool if "holdout_prose_out" in run) if ratio]
    if not ratios:
        return result
    result = fit_model(model, runs(statistics.fmean(ratios)), version, effort)
    if "refused" not in result:
        result["rates"]["chars_per_token"] = statistics.fmean(ratios)
    return result


def fit(args):
    manifests = [json.loads(path.read_text()) for path in args.manifests]

    def joined(key):  # Manifests from the single-model probe (the first opus-5.5 run) carry no kiro_cli_version.
        return ", ".join(sorted({manifest[key] for manifest in manifests if manifest.get(key)})) or None

    db = open_evidence(args.db or state_directory(None) / "usage.sqlite3")
    try:
        results = {model: fit_pool(db, manifests, model, joined("kiro_cli_version"), joined("effort"))
                   for model in sorted({call["model"] for manifest in manifests for call in manifest["calls"]})}
    finally:
        db.close()
    extra = ("unbilled_tokens", "chars_per_token", "credit_error")
    rows = [[model, *(result.get("rates", {}).get(name) for name in (*RATE_NAMES, *extra)),
             *(result.get("ratios", {}).get(name) for name in RATE_NAMES),
             result.get("provenance", {}).get("calls"), result.get("provenance", {}).get("max_residual"),
             result.get("refused", "fit")]
            for model, result in results.items()]
    print(table(["Model", *RATE_NAMES, *extra, *(f"{name} ratio" for name in RATE_NAMES), "Calls", "Max residual",
                 "Status"], rows))
    print(f"Ratio = fitted / ({discount.PROFILE_MODEL} rate × multiplier share); rates in credits per token or call. "
          f"Max residual: the cold and holdout cold calls' largest |actual / line - 1|; refused when a cold call's "
          f"exceeds {RESIDUAL_LIMIT:.0%}. credit_error: RMS of (actual - predicted) / actual over those and the hits.")
    if args.write:  # each accepted model's whole entry, from these manifests alone
        manifest_names = [str(path) for path in args.manifests]
        fitted = {model: {**result["rates"], "provenance": {**result["provenance"], "manifests": manifest_names}}
                  for model, result in results.items() if "refused" not in result}
        write_json(discount.RATES_PATH, {**discount.RATES, **fitted})
        print(f"Wrote {len(fitted)} model(s) to {discount.RATES_PATH}.")
    return 0


def selected_models(args, parser):
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    models = list(dict.fromkeys(args.models.split(",")))  # a repeated id runs once
    for model in models:
        if model not in discount.WINDOWS:  # Unlisted ids, typos and routers such as auto have no window to fit.
            parser.error(f"unknown or router model: {model}; refresh with `calibration.py models`")
    return models


def experiment(args, parser, models, steps, prompts_for):
    """Preview, or with --run make, steps' paid calls for each model; (exit status, manifest path once one exists)."""
    print(f"Models {', '.join(models)}; effort {EFFORT}; {sum(map(len, steps)) * len(models)} CLI invocations, "
          "possibly more provider requests.")
    print("Cold/warm/delayed are experiment labels, not verified cache states.")
    if ("medium_delayed",) in steps:
        print("Final repeats follow >6 quiet minutes after the other calls finish.")
    if not args.run:
        print("Dry run only. Add --run to execute. No CLI commands were called.")
        return 0, None
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
    agents = {agent_name(model, label): (model, FAMILIES[label]) for model in models for step in steps for label in step}
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
        fixtures = {model: prompts_for(f"{seed}:{model}") for model in models}  # one model's call cannot warm another's
        for step in steps:
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
                        if label != steps[0][0]:
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
        return 1, manifest_path
    finally:
        db.close()
        for sig, handler in previous_handlers.items():
            signal.signal(sig, handler)
    print(f"Complete: {len(manifest['calls'])} CLI invocations. Manifest: {manifest_path}")
    return 0, manifest_path


def prose_chars_per_token(rates, call):
    """holdout_prose_out's chars per output token, its output solved from credits as a full miss (cached 0).

    None when credits leave no positive output or the reply no chars.
    """
    output = ((call.credits - rates["fixed_per_call"] - rates["miss_input"] * discount.billed(rates, call.input + call.output))
              / (rates["output"] - rates["miss_input"]))
    return call.chars / output if output > 0 and call.chars else None


def evaluate(manifest, path):
    """Each holdout call against rates.json at its designed cache state; non-zero when one fails or is missing, or its
    model has no rates."""
    db = open_evidence(path or state_directory(None) / "usage.sqlite3")
    try:
        calls = fit_calls(db, manifest)
    finally:
        db.close()
    rows, failed = [], False
    # Requested models too: a model whose calls never ran (e.g. "calls": []) must report missing, not pass.
    for model in sorted({*manifest.get("models", ()), *(call["model"] for call in manifest["calls"])}):
        rates, observed = discount.RATES.get(model), calls.get(model, {})
        for label in HOLDOUT_LABELS:
            call = observed.get(label)
            if rates is None or call is None:
                failed = True
                rows.append([model, label, *[None] * 8, "no rates" if rates is None else "missing"])
                continue
            # Cached by design: a warm repeat's whole input, a cold call's none.
            predicted = discount.price(rates, call.input, call.output, call.input if label.endswith("_warm") else 0)
            residual = call.credits - predicted
            ratio = prose_chars_per_token(rates, call) if label == "holdout_prose_out" else None
            passed = abs(residual) <= max(TOLERANCE[0] * call.credits, TOLERANCE[1])
            failed |= not passed
            rows.append([model, label, call.input, call.output, round(call.credits, 6), round(predicted, 6),
                         round(residual, 6), round(100 * residual / call.credits, 2),
                         call.cached, ratio and round(ratio, 3), "PASS" if passed else "FAIL"])
    print(table(["Model", "Call", "Input", "Output", "Actual", "Predicted", "Residual", "Residual %", "Cached est",
                 "Chars/token", "Status"], rows))
    print(f"PASS: |actual - predicted| <= max({TOLERANCE[0]:.0%} of actual, {TOLERANCE[1]} credits), cached fixed by "
          "design (0 cold, input warm). Chars/token: prose_out's chars over its output solved from credits at cached 0.")
    return int(failed)


def validate(args, parser):
    if args.manifest:
        if args.run:
            parser.error("a manifest is evaluated offline; drop --run")
        return evaluate(json.loads(args.manifest.read_text()), args.db)
    status, manifest_path = experiment(args, parser, selected_models(args, parser), HOLDOUT_STEPS, holdout_prompts)
    if status or manifest_path is None:
        return status
    return evaluate(json.loads(manifest_path.read_text()), args.db)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    evidence = argparse.ArgumentParser(add_help=False)
    evidence.add_argument("--db", type=Path, help="collector database; defaults to runtime state directory")
    paid = argparse.ArgumentParser(add_help=False)
    paid.add_argument("--models", default=discount.PROFILE_MODEL, help="comma-separated model ids from models.json")
    paid.add_argument("--run", action="store_true", help="authorize the paid CLI invocations the preview counts")
    paid.add_argument("--timeout", type=float, default=180, help="seconds per CLI command")
    commands = parser.add_subparsers(dest="command", required=True)
    probe = commands.add_parser("probe", parents=[evidence, paid], help="preview, or with --run make, the paid probe calls")
    probe.add_argument("--sweep", action="store_true", help="add the cold prose sweep calls to the miss line")
    commands.add_parser("models", help="refresh models.json from the free kiro-cli chat --list-models")
    fitting = commands.add_parser("fit", parents=[evidence], help="fit per-model rates from probe manifests and their captures")
    fitting.add_argument("manifests", type=Path, nargs="+", help="probe or sweep manifests; each model's calls pool")
    fitting.add_argument("--write", action="store_true", help="replace accepted models' rates.json entries")
    holdout = commands.add_parser("validate", parents=[evidence, paid],
                                  help="preview, or with --run make, holdout calls; with MANIFEST evaluate them offline")
    holdout.add_argument("manifest", type=Path, nargs="?")
    args = parser.parse_args()
    if args.command == "models":
        refresh_models()
        return 0
    if args.command == "fit":
        return fit(args)
    if args.command == "validate":
        return validate(args, holdout)
    steps = STEPS[:-1] + SWEEP_STEPS * args.sweep + STEPS[-1:]  # medium_delayed stays last, after its quiet wait
    return experiment(args, probe, selected_models(args, probe), steps, prompts)[0]


if __name__ == "__main__":
    raise SystemExit(main())
