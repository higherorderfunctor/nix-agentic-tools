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
MANIFEST = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else None
SPEC = importlib.util.spec_from_file_location("observation_command", SCRIPTS / "pacing-list.py")
COMMAND = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COMMAND)
FIXTURE = Path(__file__).with_name("reader-snapshots.json")
NOW = 1794447300
READER_SHELL = shutil.which("bash")


class ObservationCommand(unittest.TestCase):
    def setUp(self):
        self.saved = json.loads(FIXTURE.read_text())
        # Nix supplies the real catalog projection in the decisive check. The
        # local Python run exercises only collection and offline behavior.
        if MANIFEST:
            self.projections = json.loads(MANIFEST.read_text())
            # Exercise all transports together below, after checking each real
            # runtime projection independently (API/subscription are disjoint).
            self.manifest = {"runtime": "fixture-collection", "pools": {
                **self.projections["inspection"]["pools"], **self.projections["subscription"]["pools"],
            }}
        else:
            self.manifest = {"runtime": "inspection", "pools": copy.deepcopy(self.saved["pools"])}
        root = os.environ["OBSERVATION_TEST_ROOT"]
        self.directory = tempfile.TemporaryDirectory(prefix="observation-", dir=root)
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.original_commands = {pool: value.get("command") for pool, value in self.manifest["pools"].items()}
        for pool, registration in self.manifest["pools"].items():
            data = self.root / (pool + ".json")
            data.write_text(json.dumps(self.saved["readers"][pool]["data"]))
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
        with patch.dict(os.environ, self.environment, clear=True):
            return COMMAND.collect(self.manifest, NOW, READER_SHELL)

    def test_catalog_projection(self):
        if MANIFEST:
            self.assertEqual(sorted(self.projections["inspection"]["pools"]), ["anthropic-api", "codex", "opencode-go", "z-ai"])
            self.assertEqual(list(self.projections["subscription"]["pools"]), ["claude"])
            self.assertEqual(shlex.split(self.original_commands["anthropic-api"]), ["fake-reader", "anthropic-api", "--limit", "200", "--reset-day", "1", "--time-zone", "UTC", "--pool", "anthropic-api", "--now-ms", "<now-ms>"])
        self.assertEqual(sorted(self.manifest["pools"]), ["anthropic-api", "claude", "codex", "opencode-go", "z-ai"])
        self.assertEqual(self.manifest["pools"]["opencode-go"]["readerPool"], "opencode")
        self.assertEqual(self.manifest["pools"]["z-ai"]["readerPool"], "zai")
        api = self.manifest["pools"]["anthropic-api"]["limits"]["monthly"]
        self.assertEqual((api["capacity"], api["unit"], api["models"]), (200, "USD", ["claude-fable-5"]))
        fable = self.manifest["pools"]["claude"]["limits"]["fable"]
        self.assertEqual((fable["window"], fable["models"]), ("7d:fable", ["claude-fable-5"]))
        self.assertEqual(self.manifest["pools"]["z-ai"]["limits"]["rolling"]["role"], "gate")

    def test_full_shapes_one_clock_and_safe_identity(self):
        captured = self.collect()
        self.assertEqual((self.root / "calls").read_text().splitlines(), ["anthropic-api", "claude", "codex", "opencode-go", "z-ai"])
        for pool, capture in captured["readers"].items():
            self.assertEqual(capture["finishedAt"], NOW)
            self.assertEqual(json.loads(capture["stdout"]), self.saved["readers"][pool]["data"])
        result = COMMAND.normalizer.normalize(captured, NOW)
        limits = result["pools"]["codex"]["limits"]
        self.assertEqual((limits[0]["remaining"], limits[0]["naturalResetAt"]), (49, 1794491425))
        self.assertEqual(result["capability"], "allowance-preview")
        self.assertNotIn("fixture-account", json.dumps(result))

    def test_shared_command_called_once(self):
        self.manifest["pools"]["codex-copy"] = copy.deepcopy(self.manifest["pools"]["codex"])
        captured = self.collect()
        self.assertEqual((self.root / "calls").read_text().splitlines().count("codex"), 1)
        self.assertEqual(captured["readers"]["codex"], captured["readers"]["codex-copy"])

    def test_failure_and_unregistered_reader_retained(self):
        self.manifest["pools"]["codex"]["command"] = "printf private-text >&2; exit 7"
        self.manifest["pools"]["z-ai"]["command"] = None
        result = COMMAND.normalizer.normalize(self.collect(), NOW)
        self.assertIn({"pool": "codex", "reason": "exit-nonzero", "exitStatus": 7}, result["diagnostics"])
        self.assertIn({"pool": "z-ai", "reason": "missing-capture"}, result["diagnostics"])
        self.assertNotIn("private-text", json.dumps(result))
        self.assertIsNone(result["pools"]["codex"]["limits"][0]["remaining"])

    def test_timeout_and_launch_failure_are_safe(self):
        for error, reason, status in [(OSError("private-path"), "refused", 127), (subprocess.TimeoutExpired("private-command", 30), "timeout", 124)]:
            with self.subTest(reason=reason), patch.object(COMMAND.subprocess, "run", side_effect=error):
                result = COMMAND.normalizer.normalize(self.collect(), NOW)
                self.assertIn({"pool": "codex", "reason": reason, "exitStatus": status}, result["diagnostics"])
                self.assertNotIn("private-", json.dumps(result))

    def test_explicit_api_clock(self):
        self.manifest["pools"] = {"anthropic-api": self.manifest["pools"]["anthropic-api"]}
        self.manifest["pools"]["anthropic-api"]["command"] += " --now-ms <now-ms>"
        with patch.object(COMMAND.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, b"{}")) as run:
            self.collect()
        self.assertTrue(run.call_args.args[0][2].endswith(" --now-ms 1794447300000"))
        self.assertEqual(run.call_args.kwargs["stderr"], subprocess.DEVNULL)

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


if __name__ == "__main__":
    unittest.main(verbosity=2)
