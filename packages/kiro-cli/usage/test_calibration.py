"""Calibration safety tests use fake executables and a private fixture database."""
# cspell:words getppid

import contextlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import signal
import sqlite3
import sys
import tempfile
import time
import unittest
from unittest.mock import MagicMock, patch

import calibration
from capture import SCHEMA

FAKE = '''import json, os, pathlib, sqlite3, subprocess, sys, time
args = sys.argv[1:]
state = pathlib.Path(os.environ["CALIBRATION_STATE"])
mode = os.environ.get("CALIBRATION_MODE", "normal")
if pathlib.Path(sys.argv[0]).name == "kiro-usage":
    if args[0] == "index":
        sys.exit(3 if mode == "index-fail" else 0)
    os.execvp(args[1], args[1:])
if args[:2] == ["agent", "validate"]:
    sys.exit(0)
if args == ["--version"]:
    print("kiro-cli 9.9.9")
    sys.exit(0)
if "--list-models" in args:
    print(json.dumps({"models": [{"model_id": "auto", "model_name": "auto", "context_window_tokens": 1000000, "rate_multiplier": 1.0},
                                 {"model_id": "m-1", "model_name": "m-1", "context_window_tokens": 200000, "rate_multiplier": 0.4}],
                      "default_model": "auto"}))
    sys.exit(0)
current = json.loads(state.read_text()) if state.exists() else []
if "--list-sessions" in args:
    print(json.dumps([{"cwd": os.getcwd(), "sessions": [{"sessionId": value} for value in current], "complete": True}]))
    sys.exit(0)
with open(str(state) + ".calls", "a") as calls:
    calls.write(json.dumps(args) + "\\n")
print("partial output", flush=True)
if mode in ("term", "hup"):
    import signal
    os.kill(os.getppid(), signal.SIGTERM if mode == "term" else signal.SIGHUP)
    time.sleep(20)
if mode == "timeout":
    subprocess.Popen([sys.executable, "-c", "import time; time.sleep(20)"])
    time.sleep(20)
if mode == "fail" or mode == "reject:" + args[args.index("--model") + 1]:
    sys.exit(7)
if "--resume-id" in args:
    session = args[args.index("--resume-id") + 1]
else:
    session = "sess_" + str(len(current) + 1)
    current.append(session)
    if mode == "ambiguous":
        current.append("sess_extra")
    state.write_text(json.dumps(current))
if mode != "no-captures":
    with sqlite3.connect(os.environ["CALIBRATION_DB"]) as db:
        db.execute("INSERT INTO captures (id,started_utc_ns,metadata_json,state,issues_json,request_gzip,dropped_bytes,credits,context_usage_percentage) VALUES (?,?,?,?,?,?,?,?,?)",
                   (str(time.time_ns()),time.time_ns(),json.dumps({"kiro:conversation_id":session.removeprefix("sess_")}),"incomplete" if mode == "incomplete" else "complete","[\\"transport_error\\"]" if mode == "incomplete" else "[]",None if mode == "incomplete" else b"retained",0,0.01,2.0))
if mode == "descendant":
    subprocess.Popen([sys.executable, "-c", "import time; time.sleep(20)"])
'''


class CalibrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.binary = self.root / "bin"
        self.binary.mkdir()
        for name in ("kiro-cli", "kiro-usage"):
            path = self.binary / name
            path.write_text(f"#!{sys.executable}\n" + FAKE)
            path.chmod(0o700)
        self.db_path = self.root / "usage.sqlite3"
        with contextlib.closing(sqlite3.connect(self.db_path)) as db:
            db.executescript(SCHEMA)
        self.environment = {"PATH": str(self.binary) + os.pathsep + os.environ["PATH"],
                            "CALIBRATION_STATE": str(self.root / "sessions.json"),
                            "CALIBRATION_DB": str(self.db_path)}

    def execute(self, mode="normal", run=True, models=None, command="probe", extra=()):
        arguments = ["calibration", command, "--db", str(self.db_path), "--timeout", "0.6", *extra] + (["--models", models] if models else [])
        if run:
            arguments.append("--run")
        output = io.StringIO()
        # Only the paid experiment's quiet delay is bypassed; subprocess timeout stays real.
        with patch.dict(os.environ, {**self.environment, "CALIBRATION_MODE": mode}), \
                patch.object(sys, "argv", arguments), patch.object(calibration, "DELAY_SECONDS", 0), \
                patch.object(calibration, "CAPTURE_WAIT", 0.2), \
                patch.object(calibration, "CAPTURE_SETTLE", 0.01), contextlib.redirect_stdout(output):
            old_umask = os.umask(0o077)
            try:
                status = calibration.main()
            finally:
                os.umask(old_umask)
        text = output.getvalue()
        if not run:
            return status, text, []
        marker = "Artifacts and workspace retained at: "
        run_root = Path(next(line[len(marker):] for line in text.splitlines() if line.startswith(marker)))
        self.addCleanup(shutil.rmtree, run_root)
        manifest = json.loads((run_root / "results/manifest.json").read_text())
        calls_path = self.root / "sessions.json.calls"
        calls = [json.loads(line) for line in calls_path.read_text().splitlines()] if calls_path.exists() else []
        return status, (manifest, run_root, text), calls

    def test_dry_run_never_executes(self):
        with patch.object(calibration.subprocess, "Popen", side_effect=AssertionError("CLI called")):
            status, _, calls = self.execute(run=False)
        self.assertEqual((status, calls), (0, []))

    def test_complete_run_and_explicit_resumes(self):
        status, (manifest, root, output), calls = self.execute()
        diagnostic = output + "\n" + json.dumps(manifest, indent=2)
        diagnostic += "\n".join(f"{path.name}: {path.read_text(errors='replace')}"
                                for path in sorted((root / "results").glob("*.stderr.log")))
        self.assertEqual(status, 0, diagnostic)
        self.assertEqual(len(calls), 10)
        resumes = [call[call.index("--resume-id") + 1] for call in calls if "--resume-id" in call]
        self.assertEqual(resumes, ["sess_7", "sess_7"])
        self.assertEqual(calls[0][-1], calls[1][-1])
        self.assertEqual(calls[0][-1], calls[9][-1])
        self.assertEqual(len({calls[index][-1].splitlines()[0] for index in (0, 2, 3)}), 3)
        self.assertTrue(all(call["status"] == "complete" and call["capture_count"] == 1
                            and call["workspace_changes"] == [] for call in manifest["calls"]))
        self.assertEqual(manifest["index_exit_code"], 0)
        self.assertEqual(manifest["kiro_cli_version"], "9.9.9")
        agents = [call[call.index("--agent") + 1] for call in calls]
        prompt = lambda agent: json.loads((root / f"workspace/.kiro/agents/{agent}.json").read_text())["prompt"]
        self.assertEqual(len({prompt(agent) for agent in agents}), 6)
        # A shared output family let output_long hit the prefix output_short had just written.
        self.assertNotEqual(agents[4], agents[5])
        self.assertNotEqual(calls[4][-1].splitlines()[0], calls[5][-1].splitlines()[0])
        self.assertEqual({agents[index] for index in (0, 1, 9)}, {"usage-calibration-claude-opus-5.5-medium"})
        self.assertEqual({agents[index] for index in (6, 7, 8)}, {"usage-calibration-claude-opus-5.5-conversation"})
        self.assertEqual(len({agents[index] for index in (2, 3, 4)}), 3)
        self.assertEqual(len(list((root / "results").glob("*.agent-validation.*"))), 12)  # stdout and stderr of six
        self.assertLess(sum(path.stat().st_size for path in root.rglob("*") if path.is_file()), 1_000_000)
        self.assertTrue(all(path.stat().st_mode & 0o077 == 0 for path in root.rglob("*")))

    def test_models_interleave_per_step_with_one_delay(self):
        status, (manifest, root, output), calls = self.execute(models="claude-opus-5.5,claude-haiku-4.5")
        self.assertEqual((status, len(calls)), (0, 20))
        self.assertIn("20 CLI invocations", output)
        self.assertEqual(output.count("Waiting"), 1)
        order = [(call[call.index("--model") + 1], record["label"]) for call, record in zip(calls, manifest["calls"])]
        opus, haiku = "claude-opus-5.5", "claude-haiku-4.5"
        self.assertEqual(order[:6], [(opus, "medium_cold"), (opus, "medium_warm"), (haiku, "medium_cold"),
                                     (haiku, "medium_warm"), (opus, "size_short"), (haiku, "size_short")])
        self.assertEqual(order[-2:], [(opus, "medium_delayed"), (haiku, "medium_delayed")])
        self.assertTrue(all(call[call.index("--agent") + 1].startswith(f"usage-calibration-{model}-")
                            for call, (model, _) in zip(calls, order)))
        self.assertTrue((root / "workspace/.kiro/agents/usage-calibration-claude-haiku-4.5-medium.json").exists())
        self.assertNotEqual(calls[0][-1], calls[2][-1])  # per-model nonces
        resumes = [call[call.index("--resume-id") + 1] for call in calls if "--resume-id" in call]
        self.assertEqual(resumes, ["sess_13", "sess_14", "sess_13", "sess_14"])

    def test_sweep_adds_cold_prose_calls_before_the_delayed_repeat(self):
        status, text, _ = self.execute(run=False, models="claude-opus-5.5,claude-haiku-4.5", extra=["--sweep"])
        self.assertEqual(status, 0)
        self.assertIn("38 CLI invocations", text)  # (10 probe + 9 sweep) x 2 models
        status, (manifest, root, _), calls = self.execute(extra=["--sweep"])
        labels = [record["label"] for record in manifest["calls"]]
        self.assertEqual((status, labels[-10:]), (0, [label for (label,) in calibration.SWEEP_STEPS] + ["medium_delayed"]))
        self.assertEqual(len({call[-1].split("\n")[0] for call in calls[-10:-1]}), 9)  # a fresh family each
        self.assertEqual(len(list((root / "workspace/.kiro/agents").glob("*-sweep_*.json"))), 9)
        self.assertLess(len(calls[-2][-1].encode()), 128 * 1024)  # sweep_16000 fits one argv string

    def test_model_refusing_its_first_call_is_dropped_and_the_rest_continue(self):
        status, (manifest, _, output), calls = self.execute("reject:claude-haiku-4.5", models="claude-opus-5.5,claude-haiku-4.5")
        self.assertEqual((status, len(calls)), (0, 11))
        self.assertIn("claude-haiku-4.5", manifest["dropped_models"])
        self.assertEqual(sum(record["model"] == "claude-haiku-4.5" for record in manifest["calls"]), 1)
        self.assertIn("Dropped claude-haiku-4.5", output)
        (self.root / "sessions.json.calls").unlink()
        status, (manifest, _, _), calls = self.execute("reject:claude-opus-5.5")
        self.assertEqual((status, len(calls)), (1, 1))
        self.assertIn("every model failed", manifest["error"])

    def test_unknown_and_router_models_are_refused_before_any_call(self):
        for model in ("auto", "simple-task", "claude-opus-5.5,typo"):
            with self.subTest(model=model), self.assertRaises(SystemExit), \
                    contextlib.redirect_stderr(io.StringIO()), \
                    patch.object(calibration.subprocess, "Popen", side_effect=AssertionError("CLI called")):
                self.execute(run=False, models=model)

    def test_models_refresh_snapshots_the_listing_sorted(self):
        target = self.root / "models.json"
        with patch.dict(os.environ, self.environment), patch.object(calibration.discount, "MODELS_PATH", target), \
                patch.object(sys, "argv", ["calibration", "models"]):
            self.assertEqual(calibration.main(), 0)
        self.assertEqual(target.read_text(), json.dumps({"kiro_cli_version": "9.9.9", "models": {
            "auto": {"context_window_tokens": 1000000, "rate_multiplier": 1.0},
            "m-1": {"context_window_tokens": 200000, "rate_multiplier": 0.4}}}, indent=2, sort_keys=True) + "\n")

    def test_holdout_families_share_or_split_the_leading_nonce(self):
        prompts = calibration.holdout_prompts("s")
        self.assertEqual(len({calibration.agent_name("m", label) for label in calibration.HOLDOUT_LABELS}), 3)
        self.assertEqual(len({prompts[label].split("\n")[0] for label in calibration.HOLDOUT_LABELS}), 3)
        self.assertNotIn("cedar", " ".join(calibration.holdout_prompts("s").values()))  # the holdout reuses no probe text

    def test_validate_run_interleaves_models_and_evaluates(self):
        status, (manifest, root, output), calls = self.execute(models="claude-sonnet-4.6,claude-opus-5.5", command="validate")
        self.assertEqual(len(calls), 10)
        labels = [record["label"] for record in manifest["calls"]]
        self.assertEqual(labels[:4], ["holdout_small_cold", "holdout_small_warm"] * 2)  # interleaved per step
        self.assertEqual(calls[0][-1], calls[1][-1])
        self.assertFalse(any("--resume-id" in call for call in calls))
        self.assertEqual(len(list((root / "results").glob("*.agent-validation.*"))), 12)  # 2 models x 3 families x 2 logs
        self.assertRegex(output, r"claude-sonnet-4.6\s+holdout_small_cold\s.*no rates")
        # The fake captures carry no output characters, so opus-5.5's designed calls are missing and fail the run.
        self.assertRegex(output, r"claude-opus-5.5\s+holdout_small_cold\s.*missing")
        self.assertEqual(status, 1)
        (self.root / "sessions.json.calls").unlink()
        status, _, _ = self.execute(models="claude-sonnet-4.6", command="validate")
        self.assertEqual(status, 1)  # a requested model without rates fails too

    def test_validate_refuses_a_manifest_with_run(self):
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()), \
                patch.object(sys, "argv", ["calibration", "validate", "--run", str(self.root / "manifest.json")]):
            calibration.main()

    def test_run_seed_changes_prefix(self):
        self.assertNotEqual(calibration.prompts("one")["medium_cold"], calibration.prompts("two")["medium_cold"])

    def test_missing_or_incomplete_capture_stops_after_first_call(self):
        for mode in ("no-captures", "incomplete"):
            with self.subTest(mode=mode):
                calls_file = self.root / "sessions.json.calls"
                calls_file.unlink(missing_ok=True)
                status, (manifest, _, _), calls = self.execute(mode)
                self.assertEqual(status, 1)
                self.assertEqual(len(calls), 1)
                self.assertEqual(manifest["calls"][0]["status"], "failed")
                self.assertNotIn("index_exit_code", manifest)

    def test_failed_exit_and_ambiguous_session_stop_without_retry(self):
        for mode in ("fail", "ambiguous"):
            with self.subTest(mode=mode):
                (self.root / "sessions.json.calls").unlink(missing_ok=True)
                status, (manifest, _, _), calls = self.execute(mode)
                self.assertEqual((status, len(calls)), (1, 1))
                self.assertEqual(manifest["calls"][0]["status"], "failed")

    def test_timeout_retains_partial_logs_and_does_not_wait_for_descendant(self):
        started = time.monotonic()
        status, (manifest, root, _), calls = self.execute("timeout")
        self.assertLess(time.monotonic() - started, 3)
        self.assertEqual((status, len(calls)), (1, 1))
        self.assertIn("timed out", manifest["calls"][0]["error"])
        self.assertLess(len(manifest["calls"][0]["error"]), 100)
        self.assertIn("partial output", (root / "results/claude-opus-5.5.medium_cold.stdout.log").read_text())

    def test_success_does_not_wait_for_descendant_holding_output(self):
        started = time.monotonic()
        status, _, calls = self.execute("descendant")
        self.assertEqual((status, len(calls)), (0, 10))
        self.assertLess(time.monotonic() - started, 5)

    def test_index_failure_is_nonfatal(self):
        status, (manifest, _, output), calls = self.execute("index-fail")
        self.assertEqual((status, len(calls)), (0, 10))
        self.assertEqual(manifest["index_exit_code"], 3)
        self.assertIn("Retry separately: kiro-usage index", output)

    def test_termination_records_failed_manifest_and_partial_logs(self):
        for mode in ("term", "hup"):
            with self.subTest(mode=mode):
                (self.root / "sessions.json.calls").unlink(missing_ok=True)
                status, (manifest, root, _), calls = self.execute(mode)
                self.assertEqual((status, len(calls)), (1, 1))
                self.assertEqual(manifest["calls"][0]["status"], "failed")
                self.assertIn("received signal", manifest["error"])
                self.assertIn("partial output", (root / "results/claude-opus-5.5.medium_cold.stdout.log").read_text())

    def test_logs_keep_bounded_head_and_tail(self):
        code = "import sys;sys.stdout.write('HEAD'+('x'*100000)+'TAIL')"
        result = calibration.run_captured([sys.executable, "-c", code], self.root, self.root, "bounded", 2)
        self.assertEqual(result, 0)
        log = (self.root / "bounded.stdout.log").read_bytes()
        self.assertTrue(log.startswith(b"HEAD") and log.endswith(b"TAIL"))
        self.assertLess(len(log), calibration.LOG_LIMIT * 2 + 100)

    def test_complete_state_still_requires_payload_usage_and_no_issues(self):
        with contextlib.closing(sqlite3.connect(self.db_path)) as db:
            for payload, dropped, credits, context, issues in (
                    (None, 0, 1, 2, "[]"), (b"", 0, 1, 2, "[]"),
                    (b"retained", 1, 1, 2, "[]"), (b"retained", 0, None, 2, "[]"),
                    (b"retained", 0, 1, None, "[]"), (b"retained", 0, 1, 2, '["issue"]')):
                db.execute("DELETE FROM captures")
                db.execute("INSERT INTO captures (id,started_utc_ns,metadata_json,state,issues_json,request_gzip,dropped_bytes,credits,context_usage_percentage) VALUES (?,?,?,?,?,?,?,?,?)",
                           ("capture", 10, '{"kiro:conversation_id":"sess_test"}', "complete",
                            issues, payload, dropped, credits, context))
                with self.assertRaisesRegex(RuntimeError, "incomplete"):
                    calibration.capture_evidence(db, "sess_test", 5, 20)

    def test_capture_rows_must_settle_and_use_invocation_time_bounds(self):
        first = ("one", "complete", "[]", 1, 0, 1, 2)
        second = ("two", "complete", "[]", 1, 0, 1, 2)
        db = MagicMock()
        db.execute.return_value.fetchall.side_effect = [[first], [first, second], [first, second]]
        with patch.object(calibration.time, "monotonic", side_effect=[0, 0, 0, 0.1, 0.1, 0.4]), \
                patch.object(calibration.time, "sleep"):
            evidence = calibration.capture_evidence(db, "sess_test", 5, 20)
        self.assertEqual([row["id"] for row in evidence], ["one", "two"])
        self.assertEqual(db.execute.call_args.args[1], (5, 20, "sess_test", "test"))
        self.assertIn("BETWEEN ? AND ?", db.execute.call_args.args[0])

    def test_termination_signals_interrupt(self):
        for sig in (signal.SIGHUP, signal.SIGTERM):
            with self.assertRaises(KeyboardInterrupt):
                calibration.interrupted(sig, None)

    def test_readonly_database_preflight_does_not_create_missing_file(self):
        missing = self.root / "missing.sqlite3"
        with self.assertRaises(sqlite3.OperationalError):
            calibration.open_evidence(missing)
        self.assertFalse(missing.exists())


def bill(rates, input, output, cached=0):
    """Credits the synthetic captures are priced at, independent of the code under test: input less its unbilled
    tokens, of which at most all are cached."""
    input = max(input - rates.get("unbilled_tokens", 0), 0)
    cached = min(cached, input)
    return (rates["fixed_per_call"] + rates["miss_input"] * (input - cached) + rates["hit_input"] * cached
            + rates["output"] * output)


class Captures(unittest.TestCase):
    """A private collector database that fit and validate read manifests' captures from."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.db_path = self.root / "usage.sqlite3"
        with contextlib.closing(sqlite3.connect(self.db_path)) as db:
            db.executescript(SCHEMA)
        self.calls = []

    def capture(self, model, label, context, credits, chars, status="complete", output=None):
        ident = f"{model}.{label}.{len(self.calls)}"  # a label may repeat across pooled manifests
        with contextlib.closing(sqlite3.connect(self.db_path)) as db, db:
            db.execute("INSERT INTO captures (id,started_utc_ns,metadata_json,state,issues_json,request_gzip,dropped_bytes,"
                       "credits,context_usage_percentage,output_tokens,summary_json) VALUES (?,0,'{}','complete','[]',?,0,?,?,?,?)",
                       (ident, b"retained", credits, context, output,
                        json.dumps({"output_text_chars": chars, "tool_chars": 0, "reasoning_chars": 0})))
        self.calls.append({"label": label, "model": model, "status": status, "capture_count": 1, "captures": [{"id": ident}]})


class FitTests(Captures):
    """Fits read synthetic captures priced at known rates."""

    def fitted(self):
        db = calibration.open_evidence(self.db_path)
        self.addCleanup(db.close)
        return {model: calibration.fit_model(model, [calls], "v", "low")
                for model, calls in calibration.fit_calls(db, {"calls": self.calls}, calibration.discount.CHARS_PER_TOKEN).items()}

    def priced(self, model, rates, label, input, output, hit=0, chars=5):
        """One capture priced at rates, its context the tokens over model's window and its output exact."""
        credits = bill(rates, input, output, hit * input)
        self.capture(model, label, (input + output) / calibration.discount.WINDOWS[model] * 100, credits, chars,
                     output=output)

    def synthetic(self, model, share, warm_hits=True, long_output=None, short_hit=0, delayed_hit=0,
                  ratio=calibration.discount.CHARS_PER_TOKEN):
        """Calls billed exactly at opus rates times share; the output pair differs only in output.

        long_output is output_long's exact output_tokens, billed in place of its 691 chars' estimate and added to its
        context, so the pair's input stays equal. ratio is the replies' true chars per token."""
        rates = {name: calibration.discount.RATES["claude-opus-5.5"][name] * share for name in calibration.RATE_NAMES}
        window = calibration.discount.WINDOWS[model]
        added = (long_output or round(691 / ratio)) - round(9 / ratio)  # output_long's output over output_short's
        for label, context, chars, hit in (("medium_cold", 8.0, 5, 0), ("medium_warm", 8.0, 5, 1 if warm_hits else 0),
                                           ("size_short", 3.0, 5, short_hit), ("size_long", 20.0, 5, 0),
                                           ("output_short", 2.0, 9, .9), ("output_long", 2.0 + added / window * 100, 691, .9), ("medium_delayed", 8.0, 5, delayed_hit)):
            output = long_output if label == "output_long" else None
            tokens = calibration.discount.estimate(model, context, None, chars, output, ratio=ratio)
            credits = bill(rates, tokens["input_tokens"], tokens["output_tokens"], hit * tokens["input_tokens"])
            self.capture(model, label, context, credits, chars, output=output)
        return rates

    def fit(self, write=False, splits=()):
        """Runs `fit` on self.calls, cut into one manifest per split index."""
        bounds, manifests = (0, *splits, len(self.calls)), []
        for index, (start, end) in enumerate(zip(bounds, bounds[1:])):
            manifests.append(self.root / f"manifest-{index}.json")
            manifests[-1].write_text(json.dumps({"effort": "low", "kiro_cli_version": "9.9.9",
                                                 "calls": self.calls[start:end]}))
        rates = self.root / "rates.json"
        rates.write_text(calibration.discount.RATES_PATH.read_text())
        output = io.StringIO()
        with patch.object(sys, "argv", ["calibration", "fit", "--db", str(self.db_path), *map(str, manifests)] + ["--write"] * write), \
                patch.object(calibration.discount, "RATES_PATH", rates), contextlib.redirect_stdout(output):
            self.assertEqual(calibration.main(), 0)
        return output.getvalue(), json.loads(rates.read_text())

    def test_write_replaces_accepted_entries_whole_and_refuses_the_rest(self):
        """haiku-4.5's earlier chars_per_token and unbilled_tokens do not survive a fit that solved neither."""
        rates = self.synthetic("claude-haiku-4.5", .2)
        self.synthetic("claude-sonnet-4.5", .65, warm_hits=False)
        with patch.dict(calibration.discount.RATES, {"claude-haiku-4.5": {
                **calibration.discount.RATES["claude-haiku-4.5"], "chars_per_token": 3, "unbilled_tokens": 900}}):
            output, written = self.fit(write=True)
        self.assertIn("no hit observed", output)
        self.assertIn("Wrote 1 model(s)", output)
        for model in ("claude-opus-5.5", "claude-sonnet-4.5"):  # unfitted, and refused: both keep their entries
            self.assertEqual(written[model], calibration.discount.RATES[model])
        haiku = written["claude-haiku-4.5"]
        self.assertEqual(haiku.keys(), {*calibration.RATE_NAMES, "credit_error", "provenance"})
        for name in calibration.RATE_NAMES:
            self.assertAlmostEqual(haiku[name] / rates[name], 1, places=6)
        self.assertEqual({key: haiku["provenance"][key] for key in ("calls", "effort", "kiro_cli_version", "manifests")},
                         {"calls": 6, "effort": "low", "kiro_cli_version": "9.9.9",
                          "manifests": [str(self.root / "manifest-0.json")]})
        self.assertLess(haiku["provenance"]["max_residual"], 1e-9)
        self.assertRegex(output, r"claude-haiku-4.5\s.*\s1\s+6\s+\S+\s+fit\n")  # ratio 1: share .2 is 0.4/2.0

    def test_exact_output_counters_replace_the_chars_estimate(self):
        """Billed on 400 exact output tokens, not the 691 chars' estimate; a chars-only fit would skew output and fixed."""
        rates = self.synthetic("claude-haiku-4.5", .2, long_output=400)
        result = self.fitted()["claude-haiku-4.5"]
        for name in calibration.RATE_NAMES:
            self.assertAlmostEqual(result["rates"][name] / rates[name], 1, places=6)

    def test_a_repeat_counts_as_a_hit_only_below_the_hit_limit(self):
        """Half of medium_delayed hit joins the hit mean at the miss and hit midpoint; 6% hit bills 97% of its cold
        call, as claude-haiku-5.5's expired one did, and is no hit."""
        for delayed_hit, calls, hit in ((.5, 7, lambda rates: (rates["hit_input"] * 3 + rates["miss_input"]) / 4),
                                        (.06, 6, lambda rates: rates["hit_input"])):
            with self.subTest(delayed_hit=delayed_hit):
                self.calls = []
                with contextlib.closing(sqlite3.connect(self.db_path)) as db, db:
                    db.execute("DELETE FROM captures")
                rates = self.synthetic("claude-haiku-4.5", .2, delayed_hit=delayed_hit)
                result = self.fitted()["claude-haiku-4.5"]
                self.assertEqual(result["provenance"]["calls"], calls)
                self.assertAlmostEqual(result["rates"]["hit_input"] / hit(rates), 1, places=6)

    def test_a_repeat_is_priced_on_its_own_counters(self):
        """medium_warm on 200 more input and 20 output tokens than medium_cold's 15,999 and 1, as claude-haiku-5.5's
        repeats varied in output: differencing the credits would read the extra tokens as a lower discount."""
        rates = self.synthetic("claude-haiku-4.5", .2)
        warm = next(call for call in self.calls if call["label"] == "medium_warm")
        self.calls.remove(warm)
        self.priced("claude-haiku-4.5", rates, "medium_warm", 16_199, 20, hit=1)
        result = self.fitted()["claude-haiku-4.5"]
        self.assertAlmostEqual(result["rates"]["hit_input"] / rates["hit_input"], 1, places=6)

    def test_output_pair_billing_its_long_reply_lower_refuses_that_model(self):
        """claude-haiku-5.5's output_long rode output_short's cached prefix: 0.0041 credits against 0.0067."""
        self.synthetic("claude-haiku-4.5", .2)
        self.synthetic("claude-sonnet-4.5", .2)
        with contextlib.closing(sqlite3.connect(self.db_path)) as db, db:
            db.execute("UPDATE captures SET credits=(SELECT credits * .0041 / .0067 FROM captures "
                       "WHERE id LIKE 'claude-haiku-4.5.output_short.%') WHERE id LIKE 'claude-haiku-4.5.output_long.%'")
        results = self.fitted()
        self.assertEqual(results["claude-haiku-4.5"], {"refused": "output pair implies a non-positive output rate"})
        self.assertNotIn("refused", results["claude-sonnet-4.5"])

    def test_holdout_pairs_join_the_hit_mean_and_their_cold_calls_the_residual(self):
        """A pooled validate manifest: its warm pair hits half its input and its cold call bills 14% over the line,
        which max_residual records without refusing the probe's own fit or moving the hit rate."""
        rates = self.synthetic("claude-haiku-4.5", .2)
        probe = len(self.calls)
        self.priced("claude-haiku-4.5", rates, "holdout_small_warm", 12_000, 1, hit=.5)
        cold = bill(rates, 12_000, 1) * 1.14
        self.capture("claude-haiku-4.5", "holdout_small_cold", 12_001 / 200_000 * 100, cold, 5, output=1)
        hit = (rates["hit_input"] + (rates["miss_input"] + rates["hit_input"]) / 2) / 2  # medium_warm's and the half hit
        output, written = self.fit(write=True, splits=(probe,))
        haiku = written["claude-haiku-4.5"]
        self.assertEqual(haiku["provenance"]["calls"], 8)
        self.assertAlmostEqual(haiku["provenance"]["max_residual"], .14 / 1.14, places=6)
        self.assertGreater(haiku["credit_error"], .14 / 1.14 / 6 ** .5)  # the 14% cold call and the two hits' misses
        self.assertAlmostEqual(haiku["hit_input"] / hit, 1, places=6)

    def prose_pool(self, rates, ratio):
        """A probe replying at ratio chars per token, then a validate manifest's 200-token prose reply at that ratio."""
        probe = len(self.calls)
        self.priced("claude-haiku-4.5", rates, "holdout_prose_out", 8_000, 200, chars=round(200 * ratio))
        # chars only: the reply's tokens are what the fit solves for
        with contextlib.closing(sqlite3.connect(self.db_path)) as db, db:
            db.execute("UPDATE captures SET output_tokens=NULL WHERE id LIKE '%holdout_prose_out%'")
        return probe

    def test_prose_reply_fits_chars_per_token_and_the_refit_reads_it(self):
        """Replies at 2.5 chars per token: chars/4 reads the 5-char replies as 1 token, not 2, so the first fit's fixed
        cost carries a token of output less input. Solved from those rates the prose reply reads 199 tokens, and the
        refit at 500 / 199 reads the probe's replies as their true tokens and returns the rates billed."""
        rates = self.synthetic("claude-haiku-4.5", .2, ratio=2.5)
        _, written = self.fit(write=True, splits=(self.prose_pool(rates, 2.5),))
        haiku = written["claude-haiku-4.5"]
        self.assertAlmostEqual(haiku["chars_per_token"], 500 / 199, places=9)
        for name in calibration.RATE_NAMES:
            self.assertAlmostEqual(haiku[name] / rates[name], 1, places=6)

    def test_credit_error_past_the_limit_fits_no_chars_per_token(self):
        """A holdout cold call 14% over the line leaves credit_error near 5.5%: the entry keeps chars/4 and the rates
        fitted at it, whose fixed cost carries the token of output read as input."""
        rates = self.synthetic("claude-haiku-4.5", .2, ratio=2.5)
        probe = self.prose_pool(rates, 2.5)
        self.capture("claude-haiku-4.5", "holdout_small_cold", 12_002 / 200_000 * 100, bill(rates, 12_000, 2) * 1.14, 5)
        _, written = self.fit(write=True, splits=(probe,))
        haiku = written["claude-haiku-4.5"]
        self.assertGreater(haiku["credit_error"], calibration.CHARS_ERROR_LIMIT)
        self.assertNotIn("chars_per_token", haiku)
        self.assertAlmostEqual(haiku["fixed_per_call"] / (rates["fixed_per_call"] + rates["output"] - rates["miss_input"]),
                               1, places=6)

    UNBILLED = {"fixed_per_call": .001, "hit_input": 1.2e-7, "miss_input": 1.15e-6, "output": 5.8e-6,
                "unbilled_tokens": 2400}  # claude-haiku-5.5's shape: context% counts 2400 tokens it never bills

    def unbilled(self, rates, warm=None):
        """A probe, sweep and holdout pool priced at rates; warm prices the repeats instead when given."""
        model = "claude-haiku-5.5"
        for label, input, output in (("output_short", 7_000, 2), ("output_long", 7_000, 400), ("medium_cold", 16_000, 1),
                                     ("sweep_00500", 9_000, 1), ("sweep_01000", 20_000, 1), ("sweep_02000", 40_000, 1),
                                     ("holdout_small_cold", 12_000, 1), ("holdout_large_cold", 31_000, 1)):
            self.priced(model, rates, label, input, output)
        for label, input in (("medium_warm", 16_000), ("holdout_small_warm", 12_000), ("holdout_large_warm", 31_000)):
            self.priced(model, warm or rates, label, input, 1, hit=1)
        self.priced(model, rates, "holdout_prose_out", 7_000, 200, chars=1000)
        return model

    def test_two_hit_sizes_solve_the_unbilled_tokens_and_their_fixed_cost(self):
        """Cold and warm lines' intercepts, fixed - miss * K and fixed - hit * K, give K and fixed back; the prose
        reply's 1,000 chars over its 200 output tokens fit chars_per_token at 5."""
        model = self.unbilled(self.UNBILLED)
        output, written = self.fit(write=True)
        for name, value in self.UNBILLED.items():
            self.assertAlmostEqual(written[model][name] / value, 1, places=6)
        self.assertAlmostEqual(written[model]["chars_per_token"], 5, places=6)
        self.assertLess(written[model]["credit_error"], 1e-9)  # the hits' size-dependent miss is gone

    def test_pooled_output_pairs_average_their_rates(self):
        """A second probe's pair at twice the output rate over 798 tokens: the mean of the two rates (1.5x), not
        their pooled credits over pooled tokens (1.67x)."""
        model = self.unbilled(self.UNBILLED)
        split = len(self.calls)
        double = {**self.UNBILLED, "output": 2 * self.UNBILLED["output"]}
        for label, output in (("output_short", 2), ("output_long", 800)):
            self.priced(model, double, label, 7_000, output)
        _, written = self.fit(write=True, splits=(split,))
        self.assertAlmostEqual(written[model]["output"] / self.UNBILLED["output"], 1.5, places=6)

    def test_unbilled_tokens_outside_the_calls_refuse_the_fit(self):
        """Repeats whose line's intercept sits 0.0005 below the cold line's leave no K >= 0 to explain them."""
        rates = {**self.UNBILLED, "unbilled_tokens": 0}
        model = self.unbilled(rates, warm={**rates, "fixed_per_call": rates["fixed_per_call"] - .0005})
        self.assertRegex(self.fit()[0], rf"{model}\s.*unbilled tokens -\d+ outside 0 to the smallest call's 7000\n")

    def test_unbilled_tokens_past_any_call_refuse_the_fit(self):
        """A K of 8,000 is below every cold and warm call's input but above the output pair's and prose reply's 7,000,
        so context % cannot count it in them."""
        model = self.unbilled({**self.UNBILLED, "unbilled_tokens": 8_000})
        self.assertRegex(self.fit()[0], rf"{model}\s.*unbilled tokens 8000 outside 0 to the smallest call's 7000\n")

    def test_unbilled_tokens_below_one_percent_of_the_smallest_call_are_zero(self):
        """claude-opus-5.5's rounding artifact, a K of 15 against 7,000 input tokens, and exact data with no offset,
        whose regression noise leaves a K of -0, keep the cold line's intercept; claude-haiku-5.5's 2,400 is solved."""
        for unbilled in (15, 0):
            with self.subTest(unbilled=unbilled):
                self.calls = []
                with contextlib.closing(sqlite3.connect(self.db_path)) as db, db:
                    db.execute("DELETE FROM captures")
                rates = {**self.UNBILLED, "unbilled_tokens": unbilled}
                model = self.unbilled(rates)
                _, written = self.fit(write=True)
                self.assertAlmostEqual(written[model]["fixed_per_call"]
                                       / (rates["fixed_per_call"] - rates["miss_input"] * unbilled), 1, places=6)
                self.assertNotIn("unbilled_tokens", written[model])
                self.assertAlmostEqual(written[model]["hit_input"] / rates["hit_input"], 1, places=6)

    def test_identical_output_pair_refuses_that_model_and_fits_the_rest(self):
        """output_long totalling output_short's tokens leaves no difference to divide by; other models still fit."""
        self.synthetic("claude-haiku-4.5", .2)
        self.synthetic("claude-sonnet-4.5", .2)
        for call in self.calls:
            if call["model"] == "claude-haiku-4.5" and call["label"] == "output_long":
                with contextlib.closing(sqlite3.connect(self.db_path)) as db, db:
                    db.execute("UPDATE captures SET context_usage_percentage=2.0, summary_json=? WHERE id=?",
                               (json.dumps({"output_text_chars": 9, "tool_chars": 0, "reasoning_chars": 0}), call["captures"][0]["id"]))
        results = self.fitted()
        self.assertEqual(results["claude-haiku-4.5"], {"refused": "output pair has no token difference"})
        self.assertNotIn("refused", results["claude-sonnet-4.5"])

    def test_missing_output_call_refuses_the_fit(self):
        self.synthetic("claude-haiku-4.5", .2)
        self.calls = [call for call in self.calls if call["label"] != "output_long"]
        output, written = self.fit(write=True)
        self.assertIn("needs output_long, output_short and three cold calls", output)
        self.assertIn("Wrote 0 model(s)", output)
        self.assertEqual(written, calibration.discount.RATES)

    def test_cold_call_off_the_miss_line_refuses_the_fit(self):
        """size_short billed 10% of its input as hits stays within 2.4%; 30% hits (8.7%) or a 50% surcharge (8.3%)
        leave a cold call more than 5% off the line, so the model is refused."""
        for short_hit, refused in ((0, None), (.1, None), (.3, "cold calls disagree"), (-.5, "cold calls disagree")):
            with self.subTest(short_hit=short_hit):
                self.calls = []
                with contextlib.closing(sqlite3.connect(self.db_path)) as db, db:
                    db.execute("DELETE FROM captures")
                self.synthetic("claude-haiku-4.5", .2, short_hit=short_hit)
                self.assertEqual(self.fitted()["claude-haiku-4.5"].get("refused"), refused)

    def test_least_squares_spans_every_cold_call(self):
        """Errors of +1, -2 and +1 share of size_short's credits on evenly spaced inputs cancel, so the rates return."""
        model, rates = "claude-sonnet-5.5", calibration.discount.RATES["claude-sonnet-5.5"]
        error = .01 * bill(rates, 9_000, 1)
        for label, input, offset in (("size_short", 9_000, error), ("medium_cold", 16_000, -2 * error),
                                     ("size_long", 23_000, error)):
            self.capture(model, label, (input + 1) / calibration.discount.WINDOWS[model] * 100,
                         bill(rates, input, 1) + offset, 5, output=1)
        for label, input, output, hit in (("medium_warm", 16_000, 1, 1), ("output_long", 7_000, 400, .9),
                                          ("output_short", 7_000, 2, .9)):
            self.priced(model, rates, label, input, output, hit)
        result = self.fitted()[model]
        self.assertNotIn("refused", result)
        for name in ("fixed_per_call", "miss_input", "output"):  # hit_input carries medium_cold's own error
            self.assertAlmostEqual(result["rates"][name] / rates[name], 1, places=6)
        self.assertEqual(result["provenance"]["calls"], 6)

    def test_sweep_replaces_the_probe_cold_calls_and_pools_across_manifests(self):
        """claude-haiku-5.5's shape: the probe's medium_cold bills 14% over the line, so the probe alone is refused.
        Pooled with three sweep calls from two more manifests, one label repeated, the sweep alone draws the line."""
        model, rates = "claude-haiku-5.5", calibration.discount.RATES["claude-haiku-4.5"]
        for label, input, output, hit, scale in (("medium_cold", 16_000, 1, 0, 1.14), ("medium_warm", 16_000, 1, 1, 1),
                                                 ("output_long", 7_000, 400, 0, 1), ("output_short", 7_000, 2, 0, 1),
                                                 ("size_long", 35_000, 1, 0, 1), ("size_short", 9_500, 1, 0, 1)):
            self.capture(model, label, (input + output) / calibration.discount.WINDOWS[model] * 100,
                         calibration.discount.price(rates, input, output, hit * input) * scale, 5, output=output)
        probe = len(self.calls)
        output, _ = self.fit()
        self.assertRegex(output, r"claude-haiku-5.5\s.*cold calls disagree\n")
        for words, input in ((500, 8_000), (1000, 20_000), (500, 40_000)):
            self.priced(model, rates, f"sweep_{words:05}", input, 1)
        output, written = self.fit(write=True, splits=(probe, probe + 2))
        self.assertIn("Wrote 1 model(s)", output)
        for name in ("fixed_per_call", "miss_input", "output"):
            self.assertAlmostEqual(written[model][name] / rates[name], 1, places=6)
        self.assertEqual(written[model]["provenance"]["calls"], 6)  # three sweep calls, the output pair, medium_warm

    def test_sweep_calls_of_one_size_refuse_that_model_and_fit_the_rest(self):
        """Three sweep calls at 9,000 input tokens replace the probe's cold calls but leave no slope to regress."""
        rates = self.synthetic("claude-haiku-4.5", .2)
        self.synthetic("claude-sonnet-4.5", .2)
        for words in (500, 1000, 2000):
            self.priced("claude-haiku-4.5", rates, f"sweep_{words:05}", 9_000, 1)
        results = self.fitted()
        self.assertEqual(results["claude-haiku-4.5"], {"refused": "cold calls share one input size"})
        self.assertNotIn("refused", results["claude-sonnet-4.5"])

    def test_fewer_than_three_sweep_calls_join_the_probe_line_and_zero_credits_drop(self):
        """One exact sweep call adds a seventh call to the line; a 0-credit one, which the collector stores, adds none."""
        rates = self.synthetic("claude-haiku-4.5", .2)
        self.priced("claude-haiku-4.5", rates, "sweep_00500", 9_000, 1)
        self.capture("claude-haiku-4.5", "sweep_01000", 10.0, 0, 5, output=1)
        result = self.fitted()["claude-haiku-4.5"]
        self.assertEqual(result["provenance"]["calls"], 7)
        self.assertAlmostEqual(result["rates"]["miss_input"] / rates["miss_input"], 1, places=6)

class ValidateTests(Captures):
    """Holdout calls billed from rates.json; a perturbed call must fail by name."""

    TOKENS = {"holdout_large_cold": (30_000, 1, 0), "holdout_large_warm": (30_000, 1, 30_000),
              "holdout_prose_out": (8_000, 200, 0), "holdout_small_cold": (12_000, 1, 0),
              "holdout_small_warm": (12_000, 1, 12_000)}  # (input, output, cached by design)

    def billed(self, model, scale=None, prose_chars=None):
        """Captures priced by model's rates at the designed cache, their chars read back at its chars_per_token."""
        rates, window = calibration.discount.RATES[model], calibration.discount.WINDOWS[model]
        for label, (input, output, cached) in self.TOKENS.items():
            credits = calibration.discount.price(rates, input, output, cached)
            chars = round(output * rates.get("chars_per_token", calibration.discount.CHARS_PER_TOKEN))
            self.capture(model, label, (input + output) / window * 100, (scale or {}).get(label, 1) * credits,
                         prose_chars if label == "holdout_prose_out" and prose_chars else chars)

    def evaluated(self, models=()):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = calibration.evaluate({"calls": self.calls, "models": list(models)}, self.db_path)
        rows = {tuple(cells[:2]): cells for cells in (re.split(r"\s{2,}", line) for line in output.getvalue().splitlines()
                                                      if line.startswith("claude-"))}
        return status, rows

    def test_holdout_billed_by_the_rates_passes_and_reads_the_prose_ratio(self):
        self.billed("claude-opus-5.5", prose_chars=1000)
        with contextlib.closing(sqlite3.connect(self.db_path)) as db, db:  # billed where priced; only the ratio moves
            db.execute("UPDATE captures SET output_tokens=200 WHERE id LIKE '%holdout_prose_out%'")
        status, rows = self.evaluated()
        self.assertEqual(status, 0)
        for label in calibration.HOLDOUT_LABELS:
            self.assertEqual(rows["claude-opus-5.5", label][-1], "PASS")
        self.assertEqual(rows["claude-opus-5.5", "holdout_prose_out"][-2], "5")  # 1,000 chars over 200 tokens

    def test_perturbed_calls_fail_by_name(self):
        """A flat 0.27 warm discount and a 5% credit error; haiku-4.5's hit/miss is 0.525, so 0.27 cannot pass."""
        cold = calibration.discount.price(calibration.discount.RATES["claude-haiku-4.5"], 12_000, 1, 0)
        warm = calibration.discount.price(calibration.discount.RATES["claude-haiku-4.5"], 12_000, 1, 12_000)
        self.billed("claude-haiku-4.5", scale={"holdout_prose_out": 1.05, "holdout_small_warm": .27 * cold / warm})
        status, rows = self.evaluated()
        self.assertEqual(status, 1)
        failed = {label for (model, label), row in rows.items() if row[-1] == "FAIL"}
        self.assertEqual(failed, {"holdout_prose_out", "holdout_small_warm"})

    def test_missing_designed_calls_fail_and_unfitted_model_reports_no_rates(self):
        """A dropped call, and a requested model without calls, are missing; an unfitted model has no rates."""
        self.billed("claude-opus-5.5")
        self.calls = [call for call in self.calls if call["label"] != "holdout_large_warm"]
        self.calls.append({"label": "holdout_small_cold", "model": "claude-sonnet-4.6", "status": "complete",
                           "capture_count": 1, "captures": [{"id": "claude-opus-5.5.holdout_small_cold"}]})
        status, rows = self.evaluated(["claude-sonnet-5.5"])
        self.assertEqual(status, 1)
        self.assertEqual(rows["claude-opus-5.5", "holdout_large_warm"][-1], "missing")
        self.assertEqual(rows["claude-sonnet-5.5", "holdout_small_cold"][-1], "missing")
        self.assertEqual({row[-1] for (model, _), row in rows.items() if model == "claude-sonnet-4.6"}, {"no rates"})

    def test_zero_credit_call_is_missing(self):
        self.billed("claude-opus-5.5", scale={"holdout_small_cold": 0})
        status, rows = self.evaluated()
        self.assertEqual((status, rows["claude-opus-5.5", "holdout_small_cold"][-1]), (1, "missing"))


if __name__ == "__main__":
    unittest.main()
