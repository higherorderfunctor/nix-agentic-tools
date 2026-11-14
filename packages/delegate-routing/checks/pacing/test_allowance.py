"""Synthetic arithmetic and CLI properties; no live Readers or catalog inventory."""

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
REFERENCE = runpy.run_path(str(Path(__file__).with_name("reference.py")))["score"]
NOW = 2000000


def limit(identifier="week", remaining=50, duration=604800, left=302400, role="pace"):
    # Normalized observations keep canonical scope separate from served aliases.
    return dict(capacity=100, enforced=True, gateOpensAt=None, id=identifier,
                models=["canonical"], naturalResetAt=NOW + left if left is not None else None,
                observedAt=NOW, readerStatus="normal", remaining=remaining, role=role,
                status="valid", unit="percentagePoint", used=100 - remaining,
                windowSeconds=duration)


def snapshot(*limits):
    # This is the normalizer's current global-offer shape, not pre-expanded routes.
    return dict(asOf=NOW, capability="allowance-preview", diagnostics=[],
                pools={"observed": dict(limits=list(limits), readerMetadata={}, scopeResolved=True)},
                routes=[dict(id="canonical", maker="synthetic", model="served-alias")], runtime="test")


class Allowance(unittest.TestCase):
    def entry(self, *limits, policy=None):
        return RANK(snapshot(*limits), policy)["entries"][0]

    def test_literal_arithmetic(self):
        # Reject clipping, idle baselines, weekly monthly divisors and gate minima.
        cases = [
            ([limit()], 1.0),
            ([limit(), limit("rolling", 10, 18000, 14400, "gate")], 1.0),
            ([limit(remaining=100)], 2.0),
            ([limit(left=3600)], 84.0),
            ([limit(), limit("month", 10, 2678400, 1339200)], 0.2),
        ]
        for limits, expected in cases:
            with self.subTest(expected=expected):
                entry = self.entry(*limits)
                self.assertEqual((entry["pace"], entry["score"], entry["state"]), (expected, expected, "ready"))

    def test_rational_reference(self):
        # Independent fractions detect arithmetic errors across differing native capacities.
        for capacity, remaining, duration, left, weight in itertools.product(
                (40, 100), (1, 10, 40), (18000, 604800, 2678400), (3600, 14400), (0, 1, 1.5)):
            observation = limit(remaining=remaining, duration=duration, left=left)
            observation.update(capacity=capacity, used=capacity - remaining)
            rows = [("pace", capacity, remaining, duration, left), ("gate", 100, 10, 18000, 14400)]
            actual = self.entry(observation, limit("gate", 10, 18000, 14400, "gate"),
                                policy={"observed": {"weight": weight}})
            self.assertAlmostEqual(actual["score"], float(REFERENCE(rows, weight)))

    def test_weights_are_unconditional(self):
        # No backing, reserve or reset eligibility exists in these inputs.
        self.assertEqual(self.entry(limit(remaining=100), policy={"observed": {"weight": 1.5}})["score"], 3)
        self.assertEqual(self.entry(limit(), policy={"observed": {}})["score"], 1)
        self.assertEqual(self.entry(limit(), policy={"observed": {"weight": 0}})["state"], "ready")
        for policy in ([], {"absent": {}}, {"observed": 2}, {"observed": {"reserve": 1}}):
            with self.subTest(policy=policy), self.assertRaises(ValueError):
                RANK(snapshot(limit()), policy)
        for weight in (-1, True, None, "1", float("nan"), float("inf")):
            with self.subTest(weight=weight), self.assertRaises(ValueError):
                RANK(snapshot(limit()), {"observed": {"weight": weight}})

    def test_unknown_evidence_and_independent_zero(self):
        # Unknown evidence must not supply a fabricated positive pace or erase zero.
        mutations = [dict(status="missing", remaining=None), dict(status="invalid"),
                     dict(status="stale"), dict(enforced=None), dict(naturalResetAt=None)]
        for mutation in mutations:
            observation = limit()
            observation.update(mutation)
            with self.subTest(mutation=mutation):
                entry = self.entry(observation)
                self.assertEqual((entry["pace"], entry["score"], entry["state"]), (None, 0, "out"))
                entry = self.entry(observation, limit("empty", remaining=0, left=None))
                self.assertEqual((entry["pace"], entry["score"], entry["state"]), (0, 0, "out"))
        self.assertIsNone(self.entry(limit(remaining=100, left=None))["pace"])
        self.assertEqual(self.entry(limit(), limit("gate", 10, 18000, None, "gate"))["score"], 1)
        self.assertEqual(self.entry(limit(), limit("gate", 0, 18000, 14400, "gate"))["state"], "out")
        unresolved = snapshot(limit())
        unresolved["pools"]["observed"]["scopeResolved"] = False
        self.assertIsNone(RANK(unresolved)["entries"][0]["pace"])

    def test_scope_and_purity(self):
        # Served aliases never act as canonical scope; unrelated pools never gain offers.
        original = snapshot(limit())
        unrelated = limit("other")
        unrelated["models"] = ["served-alias"]
        original["pools"]["unrelated"] = dict(limits=[unrelated], scopeResolved=True)
        original["routes"].append(dict(id="unscoped", maker=None, model="other"))
        before = copy.deepcopy(original)
        result = RANK(original)
        self.assertEqual(original, before)
        self.assertEqual(result["routes"], before["routes"])
        self.assertEqual([(e["id"], e["model"], e["pool"]) for e in result["entries"]],
                         [("canonical", "served-alias", "observed"), ("unscoped", "other", None)])
        self.assertIsNone(result["entries"][1]["pace"])

    def test_cli_current_shape_policy_and_failed_capture(self):
        # Exercise normalization then ranking with the same snapshot and explicit clock.
        raw = dict(runtime="test", routes=snapshot()["routes"], policy={"observed": {"weight": 1.5}},
                   pools={"observed": dict(readerPool="reader", limits={"week": dict(
                       capacity=100, models=["canonical"], role="pace", unit="percentagePoint", window="7d")})},
                   readers={"observed": dict(exit=0, finishedAt=NOW, data=dict(
                       account=dict(auth_index=None, name=None, plan=None), pool="reader", windows={"7d": dict(
                           remainingPercent=100, resetsAt=NOW + 302400, status="normal",
                           usedPercent=0, windowSeconds=604800)}))})
        command = [sys.executable, "-I", "-B", str(SCRIPTS / "pacing-list.py"),
                   "--snapshot", "/dev/stdin", "--now", str(NOW)]
        def invoke():
            return subprocess.run(command, input=json.dumps(raw), text=True, capture_output=True)
        first = invoke()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(json.loads(first.stdout)["entries"][0]["score"], 3)
        self.assertEqual(first.stdout, invoke().stdout)
        raw["readers"]["observed"]["exit"] = 7
        failed = json.loads(invoke().stdout)
        self.assertEqual(failed["routes"], raw["routes"])
        self.assertEqual((failed["entries"][0]["pace"], failed["entries"][0]["score"]), (None, 0))
        raw["policy"]["observed"]["weight"] = "private-weight"
        invalid = invoke()
        self.assertEqual((invalid.returncode, json.loads(invalid.stderr)), (2, {"reason": "invalid-input"}))
        self.assertEqual(invalid.stdout, "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
