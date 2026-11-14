"""Synthetic output properties reject lost offers, unsafe promises and unstable ties."""

import copy
import itertools
import json
from pathlib import Path
import runpy
import subprocess
import sys
import unittest

sys.dont_write_bytecode = True
SCRIPTS = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / "scripts"
RANK = runpy.run_path(str(SCRIPTS / "pacing.py"))["rank"]
AVAILABLE = runpy.run_path(str(Path(__file__).with_name("reference.py")))["availability"]
NOW = 2000000


def snapshot():
    # Actual offline input shape with synthetic identities, not pre-expanded entries.
    return dict(pools={"pool": dict(limits={
        "week": dict(capacity=100, models=["canonical"], role="pace", unit="percentagePoint", window="7d")
    }, readerPool="reader")}, readers={"pool": dict(data=dict(
        account=dict(auth_index=None, name=None, plan=None), pool="reader", windows={
            "7d": dict(remainingPercent=50, resetsAt=NOW + 302400, status="normal",
                       usedPercent=50, windowSeconds=604800)
        }), exit=0, finishedAt=NOW)}, routes=[dict(id="canonical", maker="synthetic", model="alias")], runtime="test")


def add_limit(raw, identifier, role, remaining, release):
    # Distinct windows explicitly scope every registered limit to the same canonical id.
    raw["pools"]["pool"]["limits"][identifier] = dict(
        capacity=100, models=["canonical"], role=role, unit="percentagePoint", window=identifier)
    raw["readers"]["pool"]["data"]["windows"][identifier] = dict(
        remainingPercent=remaining, resetsAt=release, status="normal",
        usedPercent=100 - remaining, windowSeconds=604800)


def cli(raw):
    command = [sys.executable, "-I", "-B", str(SCRIPTS / "pacing-list.py"),
               "--snapshot", "/dev/stdin", "--now", str(NOW)]
    result = subprocess.run(command, input=json.dumps(raw), text=True, capture_output=True)
    if result.returncode or result.stderr:
        raise AssertionError((result.returncode, result.stderr))
    return json.loads(result.stdout)


class Output(unittest.TestCase):
    def test_gate_only_availability(self):
        # Reject requiring paced allowance to report a known closed-gate release.
        for release, expected in ((NOW + 500, 2000500), (None, None), ("invalid", None)):
            with self.subTest(release=release):
                raw = snapshot()
                raw["pools"]["pool"]["limits"].clear()
                raw["readers"]["pool"]["data"]["windows"].clear()
                add_limit(raw, "rolling", "gate", 0, release)
                entry = cli(raw)["entries"][0]
                self.assertEqual((entry["available_at"], entry["pace"], entry["score"], entry["state"]),
                                 (expected, None, 0, "out"))

    def test_binding_and_all_blockers(self):
        # Reject earliest-release availability, gate minima and nondeterministic binding ties.
        raw = snapshot()
        add_limit(raw, "month", "pace", 10, NOW + 1339200)
        raw["readers"]["pool"]["data"]["windows"]["month"]["windowSeconds"] = 2678400
        entry = cli(raw)["entries"][0]
        self.assertEqual((entry["binding_limit"], entry["pace"], entry["available_at"]), ("month", 0.2, NOW))
        raw = snapshot()
        add_limit(raw, "early", "gate", 0, NOW + 100)
        add_limit(raw, "late", "gate", 0, NOW + 500)
        result = cli(raw)
        entry = result["entries"][0]
        self.assertEqual((entry["pace"], entry["score"], entry["state"], entry["available_at"]),
                         (1, 0, "out", NOW + 500))
        add_limit(raw, "empty", "pace", 0, NOW + 900)
        entry = cli(raw)["entries"][0]
        self.assertEqual((entry["binding_limit"], entry["pace"], entry["available_at"]), ("empty", 0, NOW + 900))
        add_limit(raw, "another-empty", "pace", 0, NOW + 200)
        self.assertEqual(cli(raw)["entries"][0]["binding_limit"], "another-empty")

    def test_availability_reference(self):
        # Search-based oracle rejects promises before every blocker can release.
        normalized = cli(snapshot())
        baseline = normalized["pools"]["pool"]["limits"][0]
        for releases in itertools.product((None, NOW + 10, NOW + 40), repeat=3):
            for resolved in (False, True):
                sample = copy.deepcopy(normalized)
                evidence = sample["pools"]["pool"]
                evidence["scopeResolved"] = resolved
                for index, release in enumerate(releases):
                    evidence["limits"].append(dict(baseline, id=str(index), role="gate", remaining=0,
                                                   gateOpensAt=release, naturalResetAt=release,
                                                   status="valid" if release else "invalid"))
                entry = RANK(sample)["entries"][0]
                self.assertEqual(entry["available_at"], AVAILABLE(NOW, releases, resolved))
                self.assertEqual((entry["score"], entry["state"]), (0, "out"))

    def test_unknown_and_stale_block_promises(self):
        # Every uncertainty retains independent zero but suppresses promised return times.
        mutations = [dict(resetsAt="private-invalid-time"), dict(status="unrecognized"),
                     dict(remainingPercent=None), dict(resetsAt=NOW - 1)]
        for mutation in mutations:
            raw = snapshot()
            add_limit(raw, "empty", "pace", 0, NOW + 900)
            raw["readers"]["pool"]["data"]["windows"]["7d"].update(mutation)
            entry = cli(raw)["entries"][0]
            self.assertEqual((entry["pace"], entry["score"], entry["available_at"]), (0, 0, None))
            self.assertEqual(entry["evidence"]["unknown_limits"], ["week"])
        raw = snapshot()
        raw["readers"]["pool"]["finishedAt"] = NOW - 3601
        entry = cli(raw)["entries"][0]
        self.assertEqual((entry["pace"], entry["state"], entry["available_at"]), (None, "out", None))
        self.assertEqual(entry["evidence"]["stale_limits"], ["week"])
        raw = snapshot()
        add_limit(raw, "empty", "pace", 0, "private-invalid-time")
        entry = cli(raw)["entries"][0]
        self.assertEqual((entry["pace"], entry["available_at"]), (0, None))
        self.assertEqual(entry["evidence"]["unknown_limits"], ["empty"])
        raw["readers"]["pool"]["data"]["windows"]["unregistered"] = {}
        self.assertFalse(cli(raw)["entries"][0]["evidence"]["scope_resolved"])

    def test_null_resets(self):
        # Idle pace needs a known reset; positive gates do not.
        raw = snapshot()
        add_limit(raw, "open", "gate", 10, None)
        self.assertEqual(cli(raw)["entries"][0]["available_at"], NOW)
        raw["readers"]["pool"]["data"]["windows"]["7d"].update(
            remainingPercent=100, usedPercent=0, resetsAt=None)
        entry = cli(raw)["entries"][0]
        self.assertEqual((entry["pace"], entry["available_at"]), (None, None))
        self.assertEqual(entry["evidence"]["unknown_limits"], ["week"])

    def test_retention_safe_diagnostics_and_purity(self):
        # Failed/missing captures stay visible once per applicable offer, without repeated diagnostics.
        raw = snapshot()
        raw["routes"].extend([dict(id="canonical", maker=None, model="other-alias"),
                              dict(id="unscoped", maker=None, model="unscoped")])
        raw["pools"]["failed"] = copy.deepcopy(raw["pools"]["pool"])
        raw["pools"]["missing"] = copy.deepcopy(raw["pools"]["pool"])
        raw["readers"]["failed"] = dict(exit=7, finishedAt=NOW, stdout="private-stdout", stderr="private-stderr")
        normalized = cli(raw)
        before = copy.deepcopy(normalized)
        result = RANK(normalized)
        self.assertEqual(normalized, before)
        for key in ("diagnostics", "pools", "routes"):
            self.assertEqual(result[key], before[key])
        self.assertEqual(len(result["entries"]), 7)
        self.assertEqual(result["routes"], raw["routes"])
        self.assertEqual(sum(d["reason"] == "exit-nonzero" for d in result["diagnostics"]), 1)
        self.assertNotIn("private-", json.dumps(result))
        for entry in result["entries"]:
            if entry["pool"] != "pool":
                self.assertEqual((entry["pace"], entry["score"], entry["available_at"]), (None, 0, None))
        orphan = next(e for e in result["entries"] if e["pool"] is None)
        self.assertEqual((orphan["binding_limit"], orphan["evidence"]["scope_resolved"]), (None, False))

    def test_deterministic_order(self):
        # Reject first-pool attribution and insertion-order ties, including null vs empty maker.
        raw = snapshot()
        raw["routes"] = [dict(id="canonical", maker=maker, model="alias") for maker in ("z", "", None)]
        raw["pools"]["alpha"] = copy.deepcopy(raw["pools"]["pool"])
        raw["readers"]["alpha"] = copy.deepcopy(raw["readers"]["pool"])
        raw["policy"] = {"alpha": {"weight": 0}, "pool": {"weight": 0}}
        result = cli(raw)
        expected = [(pool, maker) for pool in ("alpha", "pool") for maker in (None, "", "z")]
        self.assertEqual([(e["pool"], e["maker"]) for e in result["entries"]], expected)
        for routes in itertools.permutations(raw["routes"]):
            sample = dict(raw, routes=list(routes), pools=dict(reversed(list(raw["pools"].items()))))
            self.assertEqual(cli(sample)["entries"], result["entries"])
        raw["policy"]["pool"]["weight"] = 2
        self.assertEqual(cli(raw)["entries"][0]["pool"], "pool")
        raw["readers"]["alpha"]["exit"] = 7
        raw["policy"]["pool"]["weight"] = 0
        # Ready zero-weight entries precede out entries even with later pool names.
        self.assertEqual([e["state"] for e in cli(raw)["entries"]], ["ready"] * 3 + ["out"] * 3)


if __name__ == "__main__":
    unittest.main(verbosity=2)
