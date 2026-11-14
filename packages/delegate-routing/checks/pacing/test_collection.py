"""Exercise collection through synthetic commands for the owner check.

Typed manifests enter the library, fake process outcomes exercise shared retries,
and the normalizer exposes safe diagnostics without dropping overlapping routes.
"""

from datetime import datetime, timezone
import json
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import types
import unittest
from unittest.mock import patch

from hypothesis import given, settings, strategies as st

# The owner check supplies the packaged source directory.
SCRIPTS = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / "scripts"
C = types.SimpleNamespace(**runpy.run_path(str(SCRIPTS / "usage-collect.py")))
N = C.normalizer
settings.register_profile("collection", database=None, deadline=None, max_examples=40)
settings.load_profile("collection")
NOW = "2026-11-12T01:35:00Z"
CLOCK = datetime(2026, 11, 12, 1, 35, tzinfo=timezone.utc)
# Independent literals expose identity loss and first-credential selection.
ROUTES = [
    {"id": "canonical-a", "maker": None, "model": "served-a"},
    {"id": "canonical-a", "maker": None, "model": "served-a"},
]
ENVELOPE = json.dumps({
    "account": {"auth_index": None, "name": "private-account", "plan": None},
    "pool": "observed",
    "windows": {"7d:fable": {
        "remainingPercent": 40, "usedPercent": 60, "resetsAt": "2026-11-19T01:35:00Z",
        "status": "active", "windowSeconds": 604800,
    }},
})


def manifest(commands):
    """Parse production manifest fields while varying only registered commands."""
    return C.Manifest.model_validate({
        "pools": {f"instance/{i}": {
            "command": command, "readerPool": "observed",
            "limits": {"weekly": {
                "capacity": 100, "models": ["canonical-a"], "role": "pace",
                "unit": "percentagePoint", "window": "7d:fable",
            }},
        } for i, command in enumerate(commands)},
        "routes": ROUTES, "runtime": "codex",
    })


def collect(commands, run):
    """Keep retry waits out of generated tests while exercising the shared collector."""
    with patch.object(C.planner.collect.__globals__["time"], "sleep"):
        return C.collect(manifest(commands), NOW, "/synthetic/bash", clock=lambda: CLOCK, run=run)


class CollectionTests(unittest.TestCase):
    def test_success_keeps_literal_allowance_and_overlapping_routes(self):
        """Reject collectors that lose duplicate offers or parse allowance in the helper."""
        snapshot = collect(["reader"], lambda argv, **kw: subprocess.CompletedProcess(argv, 0, ENVELOPE, "private-stderr"))
        result = N.normalize(snapshot, NOW).model_dump()
        self.assertEqual(result["routes"], ROUTES)
        self.assertEqual(result["pools"]["instance/0"]["limits"][0]["remaining"], 40)
        self.assertEqual(result["diagnostics"], [])
        self.assertNotIn("private", json.dumps(result))

    def test_clock_substitution_and_capture_use_explicit_iso_time(self):
        """Reject wall-clock substitution and integer capture timestamps."""
        calls = []
        def run(argv, **kw):
            calls.append(argv[-1])
            return subprocess.CompletedProcess(argv, 0, ENVELOPE)
        snapshot = collect(["reader --now-ms <now-ms>"], run)
        self.assertTrue(calls[0].endswith("reader --now-ms 1794447300000"))
        self.assertEqual(snapshot.readers["instance/0"].model_dump(mode="json")["finishedAt"], NOW)

    def test_shared_runner_executes_synthetic_shell_only(self):
        """Reject a collector that captures fake results without invoking its runner."""
        shell = shutil.which("bash")
        self.assertIsNotNone(shell)
        snapshot = C.collect(manifest(["printf '%s' '{}'" ]), NOW, shell, clock=lambda: CLOCK)
        capture = snapshot.readers["instance/0"]
        self.assertEqual(capture.exit, 0)
        self.assertEqual(capture.stdout, "{}")

    @given(st.lists(st.one_of(st.none(), st.sampled_from(["read-a", "read-b", "read-c"])), min_size=1, max_size=12))
    def test_dedup_runs_each_command_once_and_keeps_credential_attribution(self, commands):
        """Reject per-credential execution and deduplication that discards credentials."""
        calls = []
        def run(argv, **kw):
            calls.append(argv[-1].splitlines()[-1])
            return subprocess.CompletedProcess(argv, 0, ENVELOPE)
        snapshot = collect(commands, run)
        self.assertCountEqual(calls, set(commands) - {None})
        self.assertEqual(set(snapshot.readers), {f"instance/{i}" for i, command in enumerate(commands) if command is not None})
        result = N.normalize(snapshot, NOW).model_dump()
        self.assertEqual(result["routes"], ROUTES)
        for i, command in enumerate(commands):
            self.assertEqual(result["pools"][f"instance/{i}"]["limits"][0]["remaining"], None if command is None else 40)

    @given(st.sampled_from(["exit", "timeout", "oserror", "unicode"]), st.integers(1, 8), st.booleans())
    def test_failure_retry_is_shared_and_diagnostics_never_leak_payload(self, outcome, duplicates, recover):
        """Reject independent retries, lost routes, raw exception text and unsafe stderr."""
        calls = []
        def run(argv, **kw):
            calls.append(argv)
            if recover and len(calls) == 2:
                return subprocess.CompletedProcess(argv, 0, ENVELOPE)
            if outcome == "timeout":
                raise subprocess.TimeoutExpired("private-command", 1, stderr="private-stderr")
            if outcome == "oserror":
                raise OSError("private-credential")
            if outcome == "unicode":
                raise UnicodeError("private-parser")
            return subprocess.CompletedProcess(argv, 9, "private-stdout", "private-stderr")
        snapshot = collect(["reader"] * duplicates, run)
        self.assertEqual(len(calls), 2)
        expected = 0 if recover else {"exit": 9, "timeout": 124, "oserror": 127, "unicode": 65}[outcome]
        self.assertEqual({capture.exit for capture in snapshot.readers.values()}, {expected})
        result = N.normalize(snapshot, NOW).model_dump()
        self.assertEqual(result["routes"], ROUTES)
        self.assertNotIn("private", json.dumps(result))
        self.assertEqual(result["diagnostics"], [] if recover else [
            {"pool": f"instance/{i}", "reason": reason, **details}
            for i in range(duplicates)
            for reason, details in [("exit-nonzero", {"exitStatus": expected}), ("missing-window", {"limit": "weekly"})]
        ])

    @given(st.sampled_from(["not json: private-parser", "[]", '{"pool":"private-credential"}']))
    def test_invalid_success_payload_is_not_retried_and_routes_survive(self, payload):
        """Reject payload retries and parser errors that escape through diagnostics."""
        calls = []
        def run(argv, **kw):
            calls.append(argv)
            return subprocess.CompletedProcess(argv, 0, payload)
        result = N.normalize(collect(["reader", "reader"], run), NOW).model_dump()
        self.assertEqual(len(calls), 1)
        self.assertEqual(result["routes"], ROUTES)
        self.assertEqual(result["pools"]["instance/0"]["limits"][0]["remaining"], None)
        self.assertNotIn("private", json.dumps(result))


if __name__ == "__main__":
    unittest.main()
