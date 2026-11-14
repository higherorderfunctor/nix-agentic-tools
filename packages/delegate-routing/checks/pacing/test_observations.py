"""Frozen production shapes and hand-written quota boundary expectations."""

import copy
import json
from pathlib import Path
import runpy
import subprocess
import sys
import unittest

sys.dont_write_bytecode = True
SCRIPTS = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / "scripts"
# Reuse the CLI's sibling loader, preserving the scripts' hyphenated filenames.
NORMALIZE = runpy.run_path(str(SCRIPTS / "pacing-list.py"))["normalizer"]
FIXTURE = Path(__file__).with_name("reader-snapshots.json")
NOW = "2026-11-12T01:35:00Z"


class Observations(unittest.TestCase):
    def setUp(self):
        self.snapshot = json.loads(FIXTURE.read_text())
        # Decode once for mutations; the committed fixture exercises stdout via the CLI.
        for capture in self.snapshot["readers"].values():
            capture["data"] = json.loads(capture.pop("stdout"))

    def result(self):
        return NORMALIZE.normalize(self.snapshot, NOW)

    def limit(self, pool, limit):
        return next(item for item in self.result()["pools"][pool]["limits"] if item["id"] == limit)

    def reasons(self):
        return [item["reason"] for item in self.result()["diagnostics"]]

    def test_production_envelopes(self):
        codex = self.limit("codex", "weekly")
        self.assertEqual((codex["capacity"], codex["remaining"], codex["used"], codex["windowSeconds"]),
            (100, 49, 51, 604800))
        self.assertEqual(codex["naturalResetAt"], 1794491425)
        self.assertEqual(codex["observedAt"], 1794447287)
        metadata = self.result()["pools"]["codex"]["readerMetadata"]
        self.assertEqual(metadata["balances"],
            [{"expiresAt": None, "kind": "credits", "remaining": 12, "unit": "credits"}])
        self.assertEqual(metadata["bonuses"], [
            {"count": 1, "expiresAt": 1893456000, "kind": "rate_limit_reset"},
            {"count": 1, "expiresAt": 1893542400, "kind": "rate_limit_reset"},
        ])

    def test_api_native_usd_and_billing_pool(self):
        api = self.limit("anthropic-api", "monthly")
        self.assertEqual((api["unit"], api["capacity"], api["readerStatus"]), ("USD", 40, "estimated"))
        self.assertAlmostEqual(api["remaining"], 30)
        self.assertAlmostEqual(api["used"], 10)
        self.assertEqual(self.limit("opencode-go", "monthly")["windowSeconds"], 2678400)
        self.assertEqual(self.limit("z-ai", "weekly")["remaining"], 37)

    def test_reader_statuses_and_scope(self):
        fable = self.limit("claude", "fable")
        self.assertEqual((fable["models"], fable["remaining"], fable["readerStatus"], fable["status"]),
            (["synthetic-fable"], 87, "active", "valid"))
        self.assertIsNone(self.limit("codex", "weekly")["enforced"])
        self.assertTrue(fable["enforced"])
        self.assertTrue(self.limit("claude", "weekly")["enforced"])
        self.assertIn("unknown-enforcement", self.reasons())
        windows = self.snapshot["readers"]["claude"]["data"]["windows"]
        self.assertEqual(self.limit("claude", "weekly")["readerStatus"], "warning")
        for status in ("critical", "inactive", "new-reader-status", None):
            windows["7d:fable"]["status"] = status
            fable = self.limit("claude", "fable")
            self.assertEqual((fable["readerStatus"], fable["status"]), (status, "valid"))
            self.assertEqual(fable["enforced"], True if status == "critical" else None)
        windows["7d:unknown"] = windows.pop("7d:fable")
        self.assertEqual(self.limit("claude", "fable")["status"], "missing")
        self.assertIn("unregistered-window", self.reasons())
        self.assertEqual(self.limit("claude", "weekly")["status"], "valid")

    def test_gate_and_idle_reset(self):
        rolling = self.limit("z-ai", "rolling")
        self.assertEqual((rolling["role"], rolling["remaining"], rolling["windowSeconds"], rolling["status"]),
            ("gate", 100, 18000, "valid"))
        self.assertIsNone(rolling["naturalResetAt"])
        self.assertEqual((self.limit("opencode-go", "rolling")["role"], self.limit("opencode-go", "rolling")["status"]),
            ("gate", "valid"))
        self.snapshot["readers"]["opencode-go"]["data"]["windows"]["5h"]["resetsAt"] = "2026-11-12T06:34:47Z"
        self.assertEqual(self.limit("opencode-go", "rolling")["status"], "valid")
        self.snapshot["readers"]["opencode-go"]["data"]["windows"]["5h"]["resetsAt"] = "2026-11-12T06:34:48Z"
        self.assertEqual(self.limit("opencode-go", "rolling")["status"], "invalid")
        self.assertEqual(self.limit("codex", "rolling")["status"], "valid")
        self.assertIsNone(self.limit("codex", "rolling")["naturalResetAt"])
        window = self.snapshot["readers"]["codex"]["data"]["windows"]["5h"]
        window.update(remainingPercent=99, usedPercent=1)
        self.assertEqual(self.limit("codex", "rolling")["status"], "invalid")

    def test_closed_rolling_gate(self):
        # Synthetic exhaustion of the saved z.ai envelope with a known release time.
        window = self.snapshot["readers"]["z-ai"]["data"]["windows"]["5h"]
        # An open gate with a known reset still has no opening time.
        window.update(resetsAt="2026-11-12T03:35:00Z")
        self.assertIsNone(self.limit("z-ai", "rolling")["gateOpensAt"])
        window.update(remainingPercent=0, usedPercent=100, resetsAt="2026-11-12T03:35:00Z")
        rolling = self.limit("z-ai", "rolling")
        self.assertEqual((rolling["remaining"], rolling["used"], rolling["role"], rolling["status"]),
            (0, 100, "gate", "valid"))
        self.assertEqual(rolling["gateOpensAt"], 1794454500)
        self.assertEqual(rolling["naturalResetAt"], 1794454500)
        self.assertNotIn("refused", rolling)
        window.update(resetsAt="2026-11-12T01:34:48Z")
        rolling = self.limit("z-ai", "rolling")
        self.assertEqual(rolling["status"], "stale")
        self.assertEqual(rolling["remaining"], 0)
        self.assertIsNone(rolling["gateOpensAt"])

    def test_missing_extras_are_unknown(self):
        del self.snapshot["readers"]["claude"]["data"]["bonuses"]
        pool = self.result()["pools"]["claude"]
        self.assertIsNone(pool["readerMetadata"]["bonuses"])
        self.assertNotIn("resets", pool)
        self.assertNotIn("credits", pool)
        self.assertEqual(pool["readerMetadata"]["balances"][0]["remaining"], 7)
        self.assertEqual(self.limit("claude", "weekly")["remaining"], 74)

    def test_failed_readers_safe_reasons(self):
        capture = self.snapshot["readers"]["anthropic-api"]
        capture.update(exit=1, data={"diagnostic": {"reason": "unpriced-models", "count": 3}},
                       stderr="private text must not escape")
        diagnostics = self.result()["diagnostics"]
        self.assertIn({"pool": "anthropic-api", "reason": "exit-nonzero", "exitStatus": 1}, diagnostics)
        capture["stdout"] = json.dumps(capture.pop("data"))
        self.assertIn({"pool": "anthropic-api", "reason": "exit-nonzero", "exitStatus": 1},
            self.result()["diagnostics"])
        capture["stdout"] = ""
        self.assertIn({"pool": "anthropic-api", "reason": "exit-nonzero", "exitStatus": 1},
            self.result()["diagnostics"])
        self.assertNotIn("private text", json.dumps(self.result()))
        self.assertIsNone(self.limit("anthropic-api", "monthly")["remaining"])

    def test_bonus_kinds_and_unknown_capture_fields(self):
        capture = self.snapshot["readers"]["claude"]
        capture["command"] = ["private-command"]
        capture["unknown"] = "private-extra"
        result = self.result()
        self.assertEqual(result["pools"]["claude"]["readerMetadata"]["bonuses"],
                         [{"count": 2, "expiresAt": None, "kind": "promo_credits"}])
        self.assertEqual(self.limit("claude", "weekly")["status"], "valid")
        self.assertNotIn("private-", json.dumps(result))

    def test_deep_stdout_failure_isolated(self):
        self.snapshot["readers"]["codex"]["stdout"] = "[" * 100000 + "0" + "]" * 100000
        command = [sys.executable, "-I", "-B", str(SCRIPTS / "pacing-list.py"),
                   "--snapshot", "/dev/stdin", "--now", NOW]
        result = subprocess.run(command, input=json.dumps(self.snapshot), text=True, capture_output=True)
        self.assertEqual((result.returncode, result.stderr), (0, ""))
        output = json.loads(result.stdout)
        self.assertEqual(output["routes"], self.snapshot["routes"])
        self.assertIn({"pool": "codex", "reason": "invalid-json"}, output["diagnostics"])
        self.assertEqual(output["pools"]["claude"]["limits"][0]["status"], "valid")
        self.assertIsNone(self.limit("codex", "weekly")["remaining"])

    def test_stdout_nesting_boundary(self):
        capture = self.snapshot["readers"]["codex"]
        document = json.dumps(capture["data"])
        for opening, closing in [("[", "]"), ('{"child":', "}")]:
            for depth in (64, 65):
                with self.subTest(opening=opening, depth=depth):
                    # The envelope itself contributes one container.
                    capture["stdout"] = document[:-1] + ',"unknown":' + opening * (depth - 1) + "0" + closing * (depth - 1) + "}"
                    result = self.result()
                    self.assertEqual(result["routes"], self.snapshot["routes"])
                    self.assertEqual(result["pools"]["claude"]["limits"][0]["status"], "valid")
                    if depth == 64:
                        self.assertEqual(self.limit("codex", "weekly")["remaining"], 49)
                    else:
                        self.assertIn({"pool": "codex", "reason": "invalid-json"}, result["diagnostics"])
                        self.assertIsNone(self.limit("codex", "weekly")["remaining"])

    def test_stdout_quoted_brackets_and_escapes(self):
        capture = self.snapshot["readers"]["codex"]
        for value in ('[{' * 100, '}]' * 100, '\\"[{' * 100, "ends with backslash\\"):
            with self.subTest(value=value):
                capture["data"]["unknown"] = value
                raw = json.dumps(capture["data"])
                for encoding in (None, "utf-8", "utf-16", "utf-32"):
                    with self.subTest(encoding=encoding):
                        capture["stdout"] = raw if encoding is None else raw.encode(encoding)
                        self.assertEqual(self.limit("codex", "weekly")["remaining"], 49)

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
        for field, value in [
            ("remainingPercent", True), ("remainingPercent", float("nan")),
            ("usedPercent", 101), ("windowSeconds", 0),
            ("resetsAt", "2026-11-17T13:00:00-07:00"), ("status", 12),
        ]:
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
        for value in [{"remaining": 49}, {**original, "account": {}}, {**original, "windows": []}]:
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
        self.assertEqual(first, subprocess.check_output(command[:-1] + ["1794447300"]))
        result = json.loads(first)
        self.assertEqual((result["capability"], result["asOf"]), ("allowance-preview", 1794447300))
        self.assertNotIn("entries", result)
        self.assertNotIn("fixture-account", first.decode())
        missing_clock = subprocess.run(command[:-2], capture_output=True)
        self.assertEqual(missing_clock.returncode, 2)
        self.assertIn(b"--now", missing_clock.stderr)


    def test_zero_survives_independent_bad_timing(self):
        # Reject erasing independently measured exhaustion on malformed timing.
        capture = self.snapshot["readers"]["codex"]
        window = capture["data"]["windows"]["7d"]
        window.update(remainingPercent=0, usedPercent=100)
        for field, value in [("windowSeconds", 0), ("resetsAt", "private-timestamp")]:
            with self.subTest(field=field):
                original = window[field]
                window[field] = value
                result = self.limit("codex", "weekly")
                self.assertEqual((result["remaining"], result["used"], result["status"]), (0, 100, "invalid"))
                self.assertNotIn("private-", json.dumps(self.result()))
                window[field] = original
        capture["finishedAt"] = "private-capture-time"
        self.assertEqual(self.limit("codex", "weekly")["remaining"], 0)
        self.assertNotIn("private-", json.dumps(self.result()))

    def test_metadata_allowlist_and_component_isolation(self):
        # Reject wholesale metadata copies and envelope rejection for bad extras.
        document = self.snapshot["readers"]["codex"]["data"]
        document["balances"][0]["secret"] = "private-extra"
        document["bonuses"].append({"kind": "private-kind", "count": 3})
        result = self.result()
        self.assertNotIn("private-", json.dumps(result))
        self.assertEqual(len(result["pools"]["codex"]["readerMetadata"]["bonuses"]), 2)
        for value in [None, {}, "private-array", [
            {"kind": "credits", "unit": "credits", "remaining": 4, "expiresAt": "private-time"},
        ]]:
            document["balances"] = value
            self.assertEqual(self.limit("codex", "weekly")["remaining"], 49)
            self.assertIn("invalid-extras", self.reasons())
            self.assertNotIn("private-", json.dumps(self.result()))

    def test_routes_retained_and_scope_explicit(self):
        # Reject route loss on capture failure and suffix-based model expansion.
        self.assertEqual(self.limit("claude", "fable")["models"], ["synthetic-fable"])
        self.assertEqual(self.limit("claude", "weekly")["models"], ["synthetic-fable", "synthetic-second"])
        self.snapshot["readers"]["claude"]["data"]["windows"]["7d:private-scope"] = {}
        result = self.result()
        self.assertFalse(result["pools"]["claude"]["scopeResolved"])
        self.assertNotIn("private-scope", json.dumps(result))
        for capture in self.snapshot["readers"].values():
            capture.update(exit=7, data={"diagnostic": {"reason": "private-error", "count": 4}})
        result = self.result()
        self.assertEqual(result["routes"], [
            {"id": "synthetic-code", "maker": "synthetic-maker", "model": "synthetic-code"},
            {"id": "synthetic-fable", "maker": "synthetic-maker", "model": "served-fable"},
            {"id": "synthetic-go", "maker": None, "model": "synthetic-go"},
            {"id": "synthetic-second", "maker": "synthetic-maker", "model": "synthetic-second"},
            {"id": "synthetic-z", "maker": "synthetic-maker", "model": "synthetic-z"},
        ])
        self.assertNotIn("private-", json.dumps(result))
        self.assertTrue(all(not p["scopeResolved"] for p in result["pools"].values()))

    def test_safe_malformed_components(self):
        # Reject exception/status payload leaks, including non-scalar values.
        capture = self.snapshot["readers"]["codex"]
        original = copy.deepcopy(capture)
        for field in ["finishedAt", "exit"]:
            for value in [{"secret": "private-text"}, True, [], "private-text"]:
                self.snapshot["readers"]["codex"] = {**original, field: value}
                self.assertNotIn("private-text", json.dumps(self.result()))
                if field == "exit" and value is True:
                    self.assertIn("invalid-exit-status", self.reasons())
        self.snapshot["readers"]["codex"] = original
        for value in [[], {}, {"secret": "private-status"}]:
            original["data"]["windows"]["7d"]["status"] = value
            self.assertEqual(self.limit("codex", "weekly")["remaining"], 49)
            self.assertNotIn("private-status", json.dumps(self.result()))

    def test_invalid_scope_registration(self):
        self.snapshot["pools"]["codex"]["limits"]["weekly"]["models"] = ["unknown"]
        with self.assertRaisesRegex(ValueError, "unknown-model"):
            self.result()

    def test_cli_safe_errors_and_failed_route_replay(self):
        # Refuse timestamp/parser payload leaks through the source CLI itself.
        command = [sys.executable, "-I", "-B", str(SCRIPTS / "pacing-list.py"),
                   "--snapshot", "/dev/stdin", "--now", NOW]
        for capture in self.snapshot["readers"].values():
            capture.update(exit=7, stderr="private-stderr")
        first = subprocess.run(command, input=json.dumps(self.snapshot), text=True, capture_output=True)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(len(json.loads(first.stdout)["routes"]), 5)
        self.assertNotIn("private-stderr", first.stdout)
        for raw, clock in [("private-json", NOW), (json.dumps(self.snapshot), "private-time")]:
            result = subprocess.run(command[:-1] + [clock], input=raw, text=True, capture_output=True)
            self.assertEqual((result.returncode, result.stdout), (2, ""))
            self.assertEqual(json.loads(result.stderr), {"reason": "invalid-input"})

    def test_replay_has_no_command_execution(self):
        # An audit hook refuses process/network events; even capture commands are data.
        source = SCRIPTS / "pacing-list.py"
        code = (
            "import runpy, sys; sys.dont_write_bytecode=True\n"
            "def audit(event, args):\n"
            " if event in {'subprocess.Popen','os.system','os.posix_spawn','socket.connect'}:\n"
            "  raise RuntimeError('execution forbidden')\n"
            "sys.addaudithook(audit)\nsys.argv="
            + repr([str(source), "--snapshot", str(FIXTURE), "--now", NOW])
            + ";runpy.run_path(" + repr(str(source)) + ",run_name='__main__')"
        )
        result = subprocess.run([sys.executable, "-I", "-B", "-c", code], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(json.loads(result.stdout)["routes"]), 5)


if __name__ == "__main__":
    unittest.main(verbosity=2)
