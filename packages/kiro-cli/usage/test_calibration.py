"""Calibration safety tests use fake executables and a private fixture database."""
# cspell:words getppid

import contextlib
import io
import json
import os
from pathlib import Path
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
if mode == "fail":
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
                   (str(time.time_ns()),time.time_ns(),json.dumps({"kiro:conversation_id":session.removeprefix("sess_")}),"incomplete" if mode == "budget" else "complete","[\\"payload_budget_exhausted\\"]" if mode == "budget" else "[]",None if mode == "budget" else b"retained",0,0.01,2.0))
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

    def execute(self, mode="normal", run=True):
        arguments = ["calibration", "--db", str(self.db_path), "--timeout", "0.6"]
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
            return status, None, []
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
        self.assertLess(sum(path.stat().st_size for path in root.rglob("*") if path.is_file()), 1_000_000)
        self.assertTrue(all(path.stat().st_mode & 0o077 == 0 for path in root.rglob("*")))

    def test_run_seed_changes_prefix(self):
        self.assertNotEqual(calibration.prompts("one")[0][1], calibration.prompts("two")[0][1])

    def test_missing_or_budget_exhausted_capture_stops_after_first_call(self):
        for mode in ("no-captures", "budget"):
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
        self.assertIn("partial output", (root / "results/medium_cold.stdout.log").read_text())

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
                self.assertIn("partial output", (root / "results/medium_cold.stdout.log").read_text())

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


if __name__ == "__main__":
    unittest.main()
