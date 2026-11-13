"""Offline delivery assertions using full saved Reader envelopes and fake commands."""

import copy
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
SCRIPTS = Path(sys.argv.pop(1))
SPEC = importlib.util.spec_from_file_location("observation_command", SCRIPTS / "pacing-list.py")
COMMAND = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COMMAND)
FIXTURE = Path(__file__).with_name("reader-snapshots.json")
NOW = 1794447300
READER_SHELL = shutil.which("bash")


class ObservationCommand(unittest.TestCase):
    def setUp(self):
        self.saved = json.loads(FIXTURE.read_text())
        self.manifest = {"runtime": "inspection", "pools": copy.deepcopy(self.saved["pools"]),
                         "routes": self.saved["routes"]}
        root = os.environ["OBSERVATION_TEST_ROOT"]
        self.directory = tempfile.TemporaryDirectory(prefix="observation-", dir=root)
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        for pool, registration in self.manifest["pools"].items():
            data = self.root / (pool + ".json")
            data.write_text(self.saved["readers"][pool]["stdout"])
            # Fake executables emit the whole saved shape, never call a Reader
            # wrapper or inherit access to an authenticated home directory.
            fake = self.root / (pool + ".py")
            fake.write_text(
                "import pathlib, sys\n"
                f"pathlib.Path({str(self.root / 'calls')!r}).open('a').write({pool!r} + '\\n')\n"
                f"sys.stdout.write(pathlib.Path({str(data)!r}).read_text())\n"
            )
            registration["command"] = shlex.join([sys.executable, "-I", str(fake)])
        self.environment = {"HOME": str(self.root), "PATH": os.defpath}

    def collect(self):
        with patch.dict(os.environ, self.environment, clear=True), patch.object(COMMAND.time, "sleep"), patch.object(COMMAND.time, "time", return_value=NOW):
            return COMMAND.collect(self.manifest, NOW, READER_SHELL)

    def test_full_shapes_one_clock_and_safe_identity(self):
        captured = self.collect()
        self.assertEqual((self.root / "calls").read_text().splitlines(), ["anthropic-api", "claude", "codex", "opencode-go", "z-ai"])
        for pool, capture in captured["readers"].items():
            self.assertEqual(capture["finishedAt"], NOW)
            self.assertEqual(json.loads(capture["stdout"]), json.loads(self.saved["readers"][pool]["stdout"]))
        result = COMMAND.normalizer.normalize(captured, NOW)
        weekly = next(item for item in result["pools"]["codex"]["limits"] if item["id"] == "weekly")
        self.assertEqual((weekly["remaining"], weekly["naturalResetAt"]), (49, 1794491425))
        self.assertEqual(result["capability"], "allowance-preview")
        self.assertNotIn("fixture-account", json.dumps(result))

    def test_failure_and_unregistered_reader_retained(self):
        self.manifest["pools"]["codex"]["command"] = "printf private-text >&2; exit 7"
        self.manifest["pools"]["z-ai"]["command"] = None
        result = COMMAND.normalizer.normalize(self.collect(), NOW)
        self.assertIn({"pool": "codex", "reason": "exit-nonzero", "exitStatus": 7}, result["diagnostics"])
        self.assertIn({"pool": "z-ai", "reason": "missing-capture"}, result["diagnostics"])
        self.assertNotIn("private-text", json.dumps(result))
        self.assertIsNone(result["pools"]["codex"]["limits"][0]["remaining"])
        self.assertEqual(result["routes"], self.saved["routes"])
        self.assertFalse(result["pools"]["z-ai"]["scopeResolved"])

    def test_actual_finish_time_and_stale_replay(self):
        # A caller's start clock cannot stamp captures or suppress replay staleness.
        with patch.object(COMMAND.time, "time", return_value=NOW + 5):
            captured = COMMAND.collect(self.manifest, NOW, READER_SHELL)
        self.assertEqual(captured["readers"]["codex"]["finishedAt"], NOW + 5)
        result = COMMAND.normalizer.normalize(captured, NOW + 3606)
        weekly = next(item for item in result["pools"]["codex"]["limits"] if item["id"] == "weekly")
        self.assertEqual(weekly["status"], "stale")

    def test_explicit_api_clock(self):
        self.manifest["pools"] = {"anthropic-api": self.manifest["pools"]["anthropic-api"]}
        self.manifest["pools"]["anthropic-api"]["command"] += " --now-ms <now-ms>"
        with patch.object(COMMAND.planner, "run_reader", return_value=subprocess.CompletedProcess([], 0, "{}")) as run:
            self.collect()
        self.assertTrue(run.call_args.args[0][-1].endswith(" --now-ms 1794447300000"))

    def test_offline_snapshot_never_launches_manifest_readers(self):
        manifest = self.root / "manifest.json"
        manifest.write_text(json.dumps({"inspection": self.manifest}))
        command = [sys.executable, "-I", str(SCRIPTS / "pacing-list.py"), "--default-manifest", str(manifest), "--snapshot", str(FIXTURE), "--now", str(NOW)]
        with patch.dict(os.environ, self.environment, clear=True):
            first = subprocess.check_output(command)
            self.assertEqual(first, subprocess.check_output(command))
        self.assertFalse((self.root / "calls").exists())
        self.assertEqual(json.loads(first)["asOf"], NOW)
        missing_clock = subprocess.run(command[:-2], capture_output=True)
        self.assertEqual(missing_clock.returncode, 2)
        self.assertIn(b"--now", missing_clock.stderr)

    def test_shared_retry_and_no_retry_for_invalid_success(self):
        # Reject per-registration retry, and retries of successful malformed output.
        registration = self.manifest["pools"]["codex"]
        self.manifest["pools"] = {"first": registration, "second": copy.deepcopy(registration)}
        for output in ["private-invalid-json", "{}", '{"account":{}}', "[" * 2000 + "0" + "]" * 2000]:
            with self.subTest(output=output), patch.object(COMMAND.planner, "run_reader", return_value=subprocess.CompletedProcess([], 0, output)) as run:
                result = COMMAND.normalizer.normalize(self.collect(), NOW)
                self.assertEqual(run.call_count, 1)
                self.assertEqual(result["routes"], self.saved["routes"])
                self.assertNotIn("private-", json.dumps(result))
        for status, results in [(7, [subprocess.CompletedProcess([], 7, "private-error")] * 2),
                                (127, [OSError("private-error")] * 2),
                                (124, [subprocess.TimeoutExpired("private-command", 30)] * 2),
                                (0, [subprocess.CompletedProcess([], 7, ""), subprocess.CompletedProcess([], 0, "{}")])]:
            with patch.object(COMMAND.planner, "run_reader", side_effect=results) as run:
                captures = self.collect()["readers"]
                result = COMMAND.normalizer.normalize({**self.manifest, "readers": captures}, NOW)
                self.assertEqual(captures["first"]["exit"], status)
                if status:
                    self.assertIn({"pool": "first", "reason": "exit-nonzero", "exitStatus": captures["first"]["exit"]}, result["diagnostics"])
                self.assertNotIn("private-", json.dumps(result))
                self.assertEqual(run.call_count, 2)
                self.assertIs(captures["first"], captures["second"])
                self.assertEqual(run.call_args.kwargs["timeout"], COMMAND.planner.READER_TIMEOUT)

    def test_fake_executable_shared_retry(self):
        # Real process attempts are deduplicated too, including a recovery.
        registration = self.manifest["pools"]["codex"]
        fake = self.root / "retry.py"
        fake.write_text(
            "import pathlib, sys\n"
            f"p = pathlib.Path({str(self.root / 'attempts')!r})\n"
            "attempt = int(p.read_text()) + 1 if p.exists() else 1\n"
            "p.write_text(str(attempt))\n"
            f"print({self.saved['readers']['codex']['stdout']!r})\n"
            "sys.exit(7 if attempt == 1 else 0)\n"
        )
        registration["command"] = shlex.join([sys.executable, "-I", "-B", str(fake)])
        self.manifest["pools"] = {"first": registration, "second": copy.deepcopy(registration)}
        result = COMMAND.normalizer.normalize(self.collect(), NOW)
        self.assertEqual((self.root / "attempts").read_text(), "2")
        self.assertEqual(next(item for item in result["pools"]["first"]["limits"] if item["id"] == "weekly")["remaining"], 49)

    def test_unregistered_scope_is_not_unrestricted(self):
        # A successful capture cannot silently promote an unmapped scope.
        del self.manifest["pools"]["claude"]["limits"]["fable"]
        result = COMMAND.normalizer.normalize(self.collect(), NOW)
        self.assertFalse(result["pools"]["claude"]["scopeResolved"])
        self.assertIn({"pool": "claude", "reason": "unregistered-window", "count": 1}, result["diagnostics"])

    def test_collection_cli_validates_before_transport(self):
        # Refuse bad registration and clock without executing configured commands.
        path = self.root / "manifest.json"
        self.manifest["pools"]["codex"]["limits"]["weekly"]["models"] = ["not-a-catalog-id"]
        path.write_text(json.dumps({"inspection": self.manifest}))
        command = [sys.executable, "-I", "-B", str(SCRIPTS / "pacing-list.py"), "--manifest", str(path), "--runtime", "inspection"]
        result = subprocess.run(command, capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stderr), {"reason": "invalid-input"})
        self.assertFalse((self.root / "calls").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
