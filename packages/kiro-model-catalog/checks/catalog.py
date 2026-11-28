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
committed = json.loads(Path(sys.argv.pop(1)).read_text())["models"]
spec = importlib.util.spec_from_file_location("catalog", source)
catalog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(catalog)


class CommittedSuggestions(unittest.TestCase):
    def test_consumer_gets_usable_suggestions(self):
        self.assertIn("claude-fable-5.1", committed, "committed fallback disappeared")
        for model in committed:
            self.assertEqual(model.split(), [model], f"invalid committed ID: {model!r}")
        # Guard the extracted set normalizer on the delivered path, not raw JSON order.
        for left, right in zip(committed, committed[1:]):
            self.assertLess(left, right, "committed IDs are duplicated or out of order")


class CatalogRefresh(unittest.TestCase):
    def setUp(self):
        work = tempfile.TemporaryDirectory()
        self.addCleanup(work.cleanup)
        self.root = Path(work.name)
        self.destination = self.root / "suggestions.json"
        self.original = b'{"models": ["old-model", "claude-sonnet-4.0"]}\n'
        self.destination.write_bytes(self.original)
        self.cli = self.root / "kiro"
        self.observed = self.root / "observed.json"
        environment = patch.dict(os.environ, {
            "AWS_PROFILE": "must-not-be-read",
            "KIRO_API_KEY": "fixture-key",
            "KIRO_HOME": "/must-not-be-read",
            "XDG_CONFIG_HOME": "/must-not-be-read",
        })
        environment.start()
        self.addCleanup(environment.stop)

    def script(self, body):
        # An assertion failure cannot masquerade as an intended CLI refusal:
        # only a correctly isolated invocation records its paths.
        self.cli.write_text(f'''#!{sys.executable}
import json, os, pathlib, sys, time
observed = pathlib.Path({str(self.observed)!r})
observed.touch()
assert sys.argv[1:] == ["chat", "--list-models", "--format", "json"]
assert sys.stdin.read() == ""
assert os.environ["KIRO_API_KEY"] == "fixture-key"
assert os.environ["KIRO_DISABLE_TELEMETRY"] == "1"
assert os.environ["KIRO_NO_AUTO_UPDATE"] == "1"
assert "KIRO_HOME" not in os.environ and "AWS_PROFILE" not in os.environ
home = pathlib.Path(os.environ["HOME"])
paths = [pathlib.Path(os.environ[name]) for name in ("XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME")]
assert len(set(paths)) == 4
assert all(not list(path.iterdir()) for path in paths)
assert set(home.iterdir()) == set(paths)
assert pathlib.Path.cwd() == home.parent
observed.write_text(json.dumps([str(path) for path in (home.parent, home, *paths)]))
{body}
''')
        self.cli.chmod(0o755)

    def reply(self, response):
        self.script(f"print({json.dumps(response)!r})")

    def run_cli(self):
        self.observed.unlink(missing_ok=True)
        return subprocess.run(
            [sys.executable, str(source), str(self.cli), str(self.destination)],
            capture_output=True,
            text=True,
        )

    def assert_clean(self):
        root = Path(json.loads(self.observed.read_text())[0])
        self.assertFalse(root.exists(), f"temporary account state remains: {root}")

    def assert_refused(self, message):
        result = self.run_cli()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, f"kiro-model-catalog: {message}\n")
        self.assertEqual(self.destination.read_bytes(), self.original)

    def assert_updated(self, models):
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.destination.read_text()), {"models": models})
        self.assert_clean()

    def test_replaces_old_ids_without_retaining_history_and_noop_keeps_bytes(self):
        # Unsorted live IDs replace stale suggestions and acquire the hidden fallback.
        self.reply({"models": [{"model_id": "nova-2.7"}, {"model_id": "auto"}]})
        self.assert_updated(["auto", "claude-fable-5.1", "nova-2.7"])

        # Backdate the file so an unnecessary same-content write cannot match its mtime.
        os.utime(self.destination, (1, 1))
        before = self.destination.read_bytes(), self.destination.stat().st_mtime_ns
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.destination.read_bytes(), self.destination.stat().st_mtime_ns), before)
        self.assert_clean()

    def test_accepts_new_provider_without_auto_or_duplicate_fallback(self):
        # A provider allowlist, required Auto, or persisted metadata would change this result.
        self.reply({"models": [
            {"model_id": "future/provider-12.34", "rate_multiplier": 99},
            {"model_id": "claude-fable-5.1"},
        ]})
        self.assert_updated(["claude-fable-5.1", "future/provider-12.34"])

    def test_refuses_invalid_catalogs_without_replacing_suggestions(self):
        invalid_ids = "expected nonempty model_id without whitespace"
        invalid_models = "expected nonempty models"
        cases = (
            ("Auto-only reply masquerades as an authenticated catalog", {"models": [{"model_id": "auto"}]}, "no concrete models (authentication may have failed)"),
            ("duplicate IDs get silently collapsed", {"models": [{"model_id": "x"}, {"model_id": "x"}]}, "duplicate model_id"),
            ("embedded whitespace becomes part of an ID", {"models": [{"model_id": "bad id"}]}, invalid_ids),
            ("empty ID becomes a suggestion", {"models": [{"model_id": ""}]}, invalid_ids),
            ("empty list becomes a fallback-only catalog", {"models": []}, invalid_models),
            ("missing list produces an unhandled key error", {}, invalid_models),
            ("non-object reply produces an unhandled attribute error", None, invalid_models),
            ("non-object row produces an unhandled attribute error", {"models": [None]}, invalid_ids),
        )
        for regression, response, message in cases:
            with self.subTest(regression=regression):
                self.reply(response)
                self.assert_refused(f"invalid catalog: {message}")
                self.assert_clean()

    def test_refuses_cli_failures_without_logging_captured_output(self):
        cases = (
            (
                "non-JSON output echoed in parse diagnostics",
                'print("fixture-key"); print("fixture-key", file=sys.stderr)',
                "invalid catalog: expected JSON",
            ),
            (
                "nonzero status ignored when stdout is parseable",
                'print(\'{"models": [{"model_id": "nova-2.7"}], "private": "fixture-key"}\'); '
                'print("fixture-key", file=sys.stderr); sys.exit(1)',
                "catalog request failed; check authentication and service availability",
            ),
        )
        for regression, body, message in cases:
            with self.subTest(regression=regression):
                self.script(body)
                self.assert_refused(message)
                self.assert_clean()

    def test_requires_a_nonblank_key_before_launch(self):
        self.script('raise AssertionError("CLI must not launch without a key")')
        cases = (
            ("absent key passes through as unauthenticated", None),
            ("empty key accepted because the variable exists", ""),
            ("whitespace accepted as a nonempty key", "   "),
        )
        for regression, key in cases:
            with self.subTest(regression=regression), patch.dict(os.environ):
                if key is None:
                    os.environ.pop("KIRO_API_KEY")
                else:
                    os.environ["KIRO_API_KEY"] = key
                self.assert_refused("authentication requires KIRO_API_KEY")
                self.assertFalse(self.observed.exists(), "started CLI without a usable key")

    def test_timeout_preserves_destination_and_cleans_home(self):
        # A stalled child must time out, not complete normally or leave account state.
        self.script('print("fixture-key", flush=True); time.sleep(10)')
        with self.assertRaisesRegex(ValueError, "^catalog request timed out$"):
            catalog.refresh(self.cli, self.destination, timeout=2)
        self.assertEqual(self.destination.read_bytes(), self.original)
        self.assert_clean()


unittest.main()
