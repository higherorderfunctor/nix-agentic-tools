"""Frozen production shapes and hand-written quota boundary expectations."""

import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest

sys.dont_write_bytecode = True
SCRIPTS = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / "scripts"
SPEC = importlib.util.spec_from_file_location("usage_normalize", SCRIPTS / "usage-normalize.py")
NORMALIZE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = NORMALIZE
SPEC.loader.exec_module(NORMALIZE)
FIXTURE = Path(__file__).with_name("reader-snapshots.json")
NOW = "2026-11-12T01:35:00Z"


class Observations(unittest.TestCase):
    def setUp(self):
        self.snapshot = json.loads(FIXTURE.read_text())

    def result(self):
        return NORMALIZE.normalize(self.snapshot, NOW)

    def limit(self, pool, limit):
        return next(item for item in self.result()["pools"][pool]["limits"] if item["id"] == limit)

    def reasons(self):
        return [item["reason"] for item in self.result()["diagnostics"]]

    def test_production_envelopes(self):
        self.assertEqual(len(self.snapshot["readers"]), 5)
        for capture in self.snapshot["readers"].values():
            self.assertEqual(set(capture), {"command", "data", "exit", "finishedAt", "startedAt", "stderrBytes"})
            self.assertEqual(set(capture["data"]), {"account", "balances", "bonuses", "pool", "windows"})
        codex = self.limit("codex", "weekly")
        self.assertEqual((codex["capacity"], codex["remaining"], codex["used"], codex["windowSeconds"]), (100, 49, 51, 604800))
        self.assertEqual(codex["naturalResetAt"], 1794491425)
        self.assertEqual(codex["observedAt"], 1794447287)
        metadata = self.result()["pools"]["codex"]["readerMetadata"]
        self.assertEqual(metadata["balances"], [{"expiresAt": None, "kind": "credits", "remaining": 62500.0, "unit": "credits"}])
        self.assertEqual(metadata["bonuses"], [{"count": 1, "expiresAt": "2026-11-30T20:20:39Z", "kind": "rate_limit_reset"}, {"count": 1, "expiresAt": "2026-12-01T22:50:26Z", "kind": "rate_limit_reset"}])

    def test_api_native_usd_and_billing_pool(self):
        api = self.limit("anthropic-api", "monthly")
        self.assertEqual((api["unit"], api["capacity"], api["readerStatus"]), ("USD", 200, "estimated"))
        self.assertAlmostEqual(api["remaining"], 134.225226705)
        self.assertAlmostEqual(api["used"], 65.774773295)
        self.assertEqual(self.limit("opencode-go", "monthly")["windowSeconds"], 2678400)
        self.assertEqual(self.limit("z-ai", "weekly")["remaining"], 37)

    def test_scoped_inactive_retained(self):
        fable = self.limit("claude", "fable")
        self.assertEqual((fable["models"], fable["remaining"], fable["readerStatus"], fable["status"]), (["claude-fable-5"], 87, "inactive", "valid"))
        self.assertIsNone(fable["enforced"])
        self.assertTrue(self.limit("claude", "weekly")["enforced"])
        self.assertIn("unknown-enforcement", self.reasons())
        windows = self.snapshot["readers"]["claude"]["data"]["windows"]
        windows["7d:unknown"] = windows.pop("7d:fable")
        self.assertEqual(self.limit("claude", "fable")["status"], "missing")
        self.assertIn("unregistered-window", self.reasons())
        self.assertEqual(self.limit("claude", "weekly")["status"], "valid")

    def test_gate_and_idle_reset(self):
        rolling = self.limit("z-ai", "rolling")
        self.assertEqual((rolling["role"], rolling["remaining"], rolling["windowSeconds"], rolling["status"]), ("gate", 100, 18000, "valid"))
        self.assertIsNone(rolling["naturalResetAt"])
        self.assertEqual(self.limit("opencode-go", "rolling")["role"], "gate")
        self.snapshot["pools"]["z-ai"]["limits"]["rolling"]["role"] = "pace"
        self.assertEqual(self.limit("z-ai", "rolling")["status"], "invalid")

    def test_closed_rolling_gate(self):
        # Synthetic exhaustion of the saved z.ai envelope with a known release time.
        window = self.snapshot["readers"]["z-ai"]["data"]["windows"]["5h"]
        self.assertIsNone(self.limit("z-ai", "rolling")["gateOpensAt"])
        window.update(remainingPercent=0, usedPercent=100, resetsAt="2026-11-12T03:35:00Z")
        rolling = self.limit("z-ai", "rolling")
        self.assertEqual((rolling["remaining"], rolling["used"], rolling["role"], rolling["status"]), (0, 100, "gate", "valid"))
        self.assertEqual(rolling["gateOpensAt"], 1794454500)
        self.assertEqual(rolling["naturalResetAt"], 1794454500)
        self.assertNotIn("refused", rolling)

    def test_missing_extras_are_unknown(self):
        del self.snapshot["readers"]["claude"]["data"]["bonuses"]
        pool = self.result()["pools"]["claude"]
        self.assertIsNone(pool["readerMetadata"]["bonuses"])
        self.assertIsNone(pool["resets"])
        self.assertIsNone(pool["credits"])
        self.assertEqual(pool["readerMetadata"]["balances"][0]["remaining"], 100)
        self.assertEqual(self.limit("claude", "weekly")["remaining"], 74)

    def test_failed_readers_safe_reasons(self):
        capture = self.snapshot["readers"]["anthropic-api"]
        capture.update(exit=1, data={"diagnostic": {"reason": "unpriced-models", "count": 3}}, stderr="private text must not escape")
        diagnostics = self.result()["diagnostics"]
        self.assertIn({"pool": "anthropic-api", "reason": "unpriced-models", "count": 3, "exitStatus": 1}, diagnostics)
        capture["stdout"] = json.dumps(capture.pop("data"))
        self.assertIn({"pool": "anthropic-api", "reason": "unpriced-models", "count": 3, "exitStatus": 1}, self.result()["diagnostics"])
        capture["stdout"] = ""
        self.assertIn({"pool": "anthropic-api", "reason": "exit-nonzero", "exitStatus": 1}, self.result()["diagnostics"])
        self.assertNotIn("private text", json.dumps(self.result()))
        self.assertIsNone(self.limit("anthropic-api", "monthly")["remaining"])

    def test_stdout_transport_and_ambiguous_accounts(self):
        capture = self.snapshot["readers"]["codex"]
        capture["stdout"] = json.dumps(capture.pop("data"))
        self.assertEqual(self.limit("codex", "weekly")["remaining"], 49)
        capture["stdout"] += capture["stdout"]
        self.assertIn("invalid-json", self.reasons())
        self.assertEqual(self.limit("codex", "weekly")["status"], "missing")

    def test_malformed_windows_isolated(self):
        windows = self.snapshot["readers"]["claude"]["data"]["windows"]
        original = copy.deepcopy(windows["7d:fable"])
        for field, value in [("remainingPercent", True), ("remainingPercent", float("nan")), ("usedPercent", 101), ("windowSeconds", 0), ("resetsAt", "2026-11-17T13:00:00-07:00"), ("status", 12)]:
            with self.subTest(field=field, value=value):
                windows["7d:fable"] = {**original, field: value}
                self.assertEqual(self.limit("claude", "fable")["status"], "invalid")
                self.assertEqual(self.limit("claude", "weekly")["status"], "valid")

    def test_missing_stale_future_and_wrong_pool(self):
        capture = self.snapshot["readers"]["codex"]
        capture["finishedAt"] = "2026-11-11T23:00:00Z"
        self.assertEqual(self.limit("codex", "weekly")["status"], "stale")
        capture["finishedAt"] = "2026-11-13T00:00:00Z"
        self.assertIn("future-observation", self.reasons())
        capture["finishedAt"] = "2026-11-12T01:34:47Z"
        capture["data"]["pool"] = "different-budget"
        self.assertIn("pool-mismatch", self.reasons())
        del self.snapshot["readers"]["codex"]
        self.assertIn("missing-capture", self.reasons())
        self.assertIsNone(self.limit("codex", "weekly")["naturalResetAt"])

    def test_simplified_and_malformed_envelopes_refused(self):
        capture = self.snapshot["readers"]["codex"]
        original = copy.deepcopy(capture["data"])
        for value in [{"remaining": 49}, {**original, "account": {}}, {**original, "bonuses": None}, {**original, "windows": []}]:
            with self.subTest(shape=list(value)):
                capture["data"] = value
                self.assertEqual(self.limit("codex", "weekly")["status"], "missing")
                self.assertEqual(self.limit("claude", "weekly")["status"], "valid")
                self.assertTrue({"invalid-envelope", "invalid-account", "invalid-extras"}.intersection(self.reasons()))
        for value in [{}, {"pools": [], "readers": {}, "runtime": "inspection"}]:
            with self.assertRaisesRegex(ValueError, "invalid-snapshot"):
                NORMALIZE.normalize(value, NOW)

    def test_no_invented_scope_or_limit_fields(self):
        value = self.snapshot["pools"]["codex"]["limits"]["weekly"]
        value["resetPolicy"] = "use"
        with self.assertRaisesRegex(ValueError, "invalid-limit-spec"):
            self.result()

    def test_cli_explicit_clock_preview_and_privacy(self):
        command = [sys.executable, "-I", str(SCRIPTS / "pacing-list.py"), "--snapshot", str(FIXTURE), "--now", NOW]
        first = subprocess.check_output(command)
        self.assertEqual(first, subprocess.check_output(command))
        result = json.loads(first)
        self.assertEqual((result["capability"], result["asOf"]), ("allowance-preview", 1794447300))
        self.assertNotIn("entries", result)
        self.assertNotIn("fixture-account", first.decode())
        missing_clock = subprocess.run(command[:-2], capture_output=True)
        self.assertEqual(missing_clock.returncode, 2)
        self.assertIn(b"--now", missing_clock.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
