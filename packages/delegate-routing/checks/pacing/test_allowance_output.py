"""Literal output contracts over frozen Reader envelopes and delivered commands."""

import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
SCRIPTS = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / "scripts"
COMMANDS = sys.argv[2:]
sys.argv[1:] = [str(SCRIPTS)]
spec = importlib.util.spec_from_file_location("allowance_cases", Path(__file__).with_name("test_allowance.py"))
cases = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cases)
NOW = cases.NOW


class Output(unittest.TestCase):
    def result(self, saved):
        normalized = cases.normalized(saved)
        before = copy.deepcopy(normalized)
        result = cases.ENGINE.rank(normalized)
        self.assertEqual(normalized, before)
        cases.Allowance().equal(result, cases.REFERENCE.rank(normalized))
        return result

    def test_literal_missing_capture_deduplication(self):
        saved = cases.fixture()
        saved["pools"]["codex"]["limits"] = {}
        saved["readers"] = {}
        saved["routes"][0]["limits"] = []
        result = self.result(saved)
        self.assertEqual(result["diagnostics"], [{"pool": "codex", "reason": "missing-capture"}])
        self.assertEqual(result["entries"], [{
            "available_at": None, "base_pace": None, "binding_limit": None,
            "cost": None, "expiring": None, "headroom": None, "maker": "openai",
            "model": "gpt-6.1-sol", "pace": None, "pool": "codex", "score": 0,
            "stale": True, "usage_state": "out",
        }])
        print("PASS missing capture: one diagnostic, retained out route, null pace/cost/time")

    def test_literal_blocked_plus_unknown(self):
        saved = cases.fixture(0, 7200)
        registration = saved["pools"]["codex"]["limits"]
        registration["scoped"] = dict(registration["weekly"], window="7d:scoped")
        saved["routes"][0]["limits"].append("scoped")
        result = self.result(saved)
        self.assertEqual(result["entries"], [{
            "available_at": None, "base_pace": None, "binding_limit": "weekly",
            "cost": None, "expiring": None, "headroom": 0, "maker": "openai",
            "model": "gpt-6.1-sol", "pace": 0, "pool": "codex", "score": 0,
            "stale": True, "usage_state": "out",
        }])
        self.assertEqual(result["diagnostics"], [
            {"pool": "codex", "reason": "missing-window", "limit": "scoped"},
            {"pool": "codex", "reason": "uncertain-allowance", "limits": ["scoped"], "model": "gpt-6.1-sol"},
        ])
        print("PASS blocked plus unknown: proven zero and binding retained, return time null, uncertainty explicit")

    def test_literal_independent_blockers_and_stale(self):
        saved = cases.fixture(0, 7200)
        registration = saved["pools"]["codex"]["limits"]
        registration["rolling"] = dict(registration["weekly"], role="gate", window="5h")
        saved["routes"][0]["limits"].append("rolling")
        windows = saved["readers"]["codex"]["data"]["windows"]
        windows["5h"] = dict(windows["7d"], resetsAt=NOW+14400, windowSeconds=18000)
        result = self.result(saved)
        row = result["entries"][0]
        self.assertEqual((row["available_at"], row["binding_limit"], row["pace"], row["stale"]), (1794461700, "rolling", 0, False))
        # An expired observation is annotated, never promised as a future refill.
        windows["5h"]["resetsAt"] = NOW
        result = self.result(saved)
        self.assertEqual((result["entries"][0]["available_at"], result["entries"][0]["stale"]), (None, True))
        self.assertIn({"pool": "codex", "model": "gpt-6.1-sol", "reason": "unknown-return"}, result["diagnostics"])
        print("PASS blockers: +2h/+4h return at +4h; elapsed release is stale with null return and diagnostic")

    def test_cli_complete_canonical_preview_and_delivery(self):
        saved = cases.fixture(0, 7200)
        saved["pools"]["codex"]["limits"]["weekly"]["models"] = ["gpt-6.1-sol", "gpt-6-astra"]
        registration = saved["pools"]["codex"]["limits"]
        registration["rolling"] = dict(registration["weekly"], role="gate", window="5h")
        windows = saved["readers"]["codex"]["data"]["windows"]
        windows["5h"] = dict(windows["7d"], remainingPercent=10, usedPercent=90, resetsAt=NOW+14400, windowSeconds=18000)
        saved["routes"][0]["limits"].append("rolling")
        saved["routes"].append(dict(saved["routes"][0], model="gpt-6-astra"))
        with tempfile.TemporaryDirectory(dir=os.environ["ALLOWANCE_TEST_ROOT"]) as root:
            source = Path(root) / "snapshot.json"
            source.write_text(json.dumps(saved))
            arguments = ["--snapshot", str(source), "--now", str(NOW)]
            direct = [sys.executable, "-I", str(SCRIPTS / "pacing-list.py")]
            expected = subprocess.check_output([*direct, *arguments])
            saved["routes"].reverse()
            for route in saved["routes"]:
                route["limits"] = list(reversed(route["limits"]))
            source.write_text(json.dumps(saved, sort_keys=True))
            self.assertEqual(subprocess.check_output([*direct, *arguments]), expected)
            for command in COMMANDS:
                self.assertEqual(subprocess.check_output([command, *arguments]), expected)
            result = json.loads(expected)
            self.assertEqual(expected.decode(), json.dumps(result, allow_nan=False, sort_keys=True, separators=(",", ":"))+"\n")
            self.assertEqual(result["capability"], "allowance-preview")
            self.assertEqual([row["model"] for row in result["entries"]], ["gpt-6-astra", "gpt-6.1-sol"])
            self.assertEqual([row["score"] for row in result["entries"]], [0, 0])
            self.assertEqual([row["usage_state"] for row in result["entries"]], ["out", "out"])
            self.assertEqual([row["available_at"] for row in result["entries"]], [1794454500, 1794454500])
            self.assertNotIn("actions", result)
            self.assertEqual((result["pools"]["codex"]["credits"], result["pools"]["codex"]["resets"]), (None, None))
            for row in result["entries"]:
                self.assertFalse({"avoidFor", "effort", "launch", "useFor"} & row.keys())
                self.assertEqual((row["cost"], row["expiring"]), (None, None))
            for command in [direct, *[[command] for command in COMMANDS]]:
                help_text = subprocess.check_output([*command, "--help"], text=True)
                self.assertIn("allowance-preview", help_text)
                self.assertIn("support is incomplete", help_text)
        print(f"PASS CLI: all zero routes, canonical bytes across permutations, preview-only fields/help; delivered commands={len(COMMANDS)}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
