"""Offline fixtures exercise the production authenticated refresh boundary."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

source = Path(sys.argv.pop(1)).resolve()
spec = importlib.util.spec_from_file_location("catalog", source)
catalog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(catalog)
if len(sys.argv) > 1 and sys.argv[1].endswith(".json"):
    committed = json.loads(Path(sys.argv.pop(1)).read_text())["models"]
    assert committed == catalog.model_ids({"models": [{"model_id": value} for value in committed]})


class CatalogRefresh(unittest.TestCase):
    def setUp(self):
        work = tempfile.TemporaryDirectory()
        self.addCleanup(work.cleanup)
        self.root = Path(work.name)
        self.destination = self.root / "suggestions.json"
        self.destination.write_text('{"models": ["old-model", "claude-sonnet-4.0"]}\n')
        self.original = self.destination.read_bytes()
        self.cli = self.root / "kiro"
        self.observed = self.root / "observed.json"
        self.script('print(\'{"models": [{"model_id": "nova-2.7"}, {"model_id": "auto"}]}\')')
        self.environment = patch.dict(os.environ, {
            "KIRO_API_KEY": "fixture-key", "KIRO_HOME": "/must-not-be-read",
            "XDG_CONFIG_HOME": "/must-not-be-read", "AWS_PROFILE": "must-not-be-read",
        })
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def script(self, body):
        self.cli.write_text(f'''#!{sys.executable}
import json, os, pathlib, sys, time
assert sys.argv[1:] == ["chat", "--list-models", "--format", "json"]
assert sys.stdin.read() == ""
assert os.environ["KIRO_API_KEY"] == "fixture-key"
assert os.environ["KIRO_DISABLE_TELEMETRY"] == "1"
assert os.environ["KIRO_NO_AUTO_UPDATE"] == "1"
assert "KIRO_HOME" not in os.environ and "AWS_PROFILE" not in os.environ
paths = [os.environ[name] for name in ("HOME", "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME")]
assert len(set(paths)) == 5
assert all(pathlib.Path(path).is_dir() and not list(pathlib.Path(path).iterdir()) for path in paths[1:])
assert all(pathlib.Path(path).parent == pathlib.Path(paths[0]) for path in paths[1:])
assert pathlib.Path.cwd() == pathlib.Path(paths[0]).parent
pathlib.Path({str(self.observed)!r}).write_text(json.dumps(paths))
{body}
''')
        self.cli.chmod(0o755)

    def run_cli(self):
        return subprocess.run([sys.executable, str(source), str(self.cli), str(self.destination)], capture_output=True, text=True)

    def assert_clean(self):
        if self.observed.exists():
            self.assertTrue(all(not Path(path).exists() for path in json.loads(self.observed.read_text())))

    def test_replaces_old_ids_without_retaining_history_and_noop_keeps_bytes(self):
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.destination.read_text()), {"models": ["auto", "claude-fable-5.1", "nova-2.7"]})
        self.assert_clean()
        before = self.destination.read_bytes(), self.destination.stat().st_mtime_ns
        self.assertEqual(self.run_cli().returncode, 0)
        self.assertEqual((self.destination.read_bytes(), self.destination.stat().st_mtime_ns), before)

    def test_refuses_invalid_responses_without_touching_destination_or_leaking_output(self):
        for response in (None, {}, {"models": []}, {"models": [None]}, {"models": [{"model_id": ""}]}, {"models": [{"model_id": "bad id"}]}, {"models": [{"model_id": "auto"}]}, {"models": [{"model_id": "x"}, {"model_id": "x"}]}):
            with self.subTest(response=response):
                self.script(f"print({json.dumps(response)!r})")
                result = self.run_cli()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.destination.read_bytes(), self.original)
                self.assert_clean()
        for body in ('print("fixture-key"); print("fixture-key", file=sys.stderr)', 'print("fixture-key", file=sys.stderr); sys.exit(1)'):
            self.script(body)
            result = self.run_cli()
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("fixture-key", result.stdout + result.stderr)
            self.assertEqual(self.destination.read_bytes(), self.original)
            self.assert_clean()

    def test_missing_key_refuses_before_launch(self):
        for key in ("", "   "):
            with patch.dict(os.environ, KIRO_API_KEY=key):
                self.assertNotEqual(self.run_cli().returncode, 0)
            self.assertFalse(self.observed.exists())
            self.assertEqual(self.destination.read_bytes(), self.original)

    def test_timeout_preserves_destination_and_cleans_home(self):
        self.script('print("fixture-key", flush=True); time.sleep(10)')
        with self.assertRaisesRegex(ValueError, "timed out"):
            catalog.refresh(self.cli, self.destination, timeout=0.2)
        self.assertEqual(self.destination.read_bytes(), self.original)
        self.assert_clean()

    def test_ids_are_data_and_auto_is_optional(self):
        self.assertEqual(catalog.model_ids({"models": [{"model_id": "future/provider-12.34", "rate_multiplier": 99}, {"model_id": "claude-fable-5.1"}]}), ["claude-fable-5.1", "future/provider-12.34"])


unittest.main()
