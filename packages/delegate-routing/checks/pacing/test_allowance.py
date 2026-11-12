"""Literal allowance expectations, independent reference and offline CLI parity."""

import ast
import copy
import importlib.util
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
SCRIPTS = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / "scripts"
MANIFEST = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else None


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


ENGINE = load("pacing", SCRIPTS / "pacing.py")
REFERENCE = load("reference", Path(__file__).with_name("reference.py"))
NORMALIZE = load("usage_normalize", SCRIPTS / "usage-normalize.py")
NOW = 1794447300


def fixture(remaining=50, left=302400, window=604800, role="pace"):
    # Synthetic amendments retain the actual Reader envelope and registration.
    saved = json.loads(Path(__file__).with_name("reader-snapshots.json").read_text())
    saved["pools"] = {"codex": saved["pools"]["codex"]}
    saved["readers"] = {"codex": saved["readers"]["codex"]}
    saved["readers"]["codex"]["finishedAt"] = NOW
    spec = saved["pools"]["codex"]["limits"]["weekly"]
    spec["role"] = role
    saved["readers"]["codex"]["data"]["windows"][spec["window"]].update(
        remainingPercent=remaining, usedPercent=100-remaining, windowSeconds=window,
        resetsAt=NOW+left if left is not None else None, status="normal")
    model = spec["models"][0]
    saved["routes"] = [{"limits": ["weekly"], "maker": "openai", "model": model, "pool": "codex"}]
    return saved


def normalized(saved):
    return {**NORMALIZE.normalize(saved, NOW), "routes": saved["routes"]}


class Allowance(unittest.TestCase):
    def equal(self, actual, expected):
        if isinstance(expected, float):
            self.assertTrue(math.isclose(actual, expected, rel_tol=1e-12, abs_tol=1e-12), (actual, expected))
        elif isinstance(expected, dict):
            self.assertEqual(actual.keys(), expected.keys())
            for key in expected:
                self.equal(actual[key], expected[key])
        elif isinstance(expected, list):
            self.assertEqual(len(actual), len(expected))
            for a, b in zip(actual, expected):
                self.equal(a, b)
        else:
            self.assertEqual(actual, expected)

    def checked(self, snapshot, policy=None):
        before = copy.deepcopy(snapshot)
        result = ENGINE.rank(snapshot, policy)
        self.equal(result, REFERENCE.rank(snapshot, policy))
        self.assertEqual(snapshot, before)
        self.assertEqual(json.dumps(result, sort_keys=True), json.dumps(ENGINE.rank(snapshot, policy), sort_keys=True))
        return result["entries"]

    def test_literal_uncapped84_idle2_open_gate1_monthly_point2(self):
        for label, remaining, left, expected in [("uncapped84", 50, 3600, 84.0), ("idle2", 100, 302400, 2.0)]:
            row = self.checked(normalized(fixture(remaining, left)))[0]
            self.equal(row["pace"], expected)
            print(f"PASS {label}: pace={expected}")
        data = normalized(fixture())
        weekly = data["pools"]["codex"]["limits"][0]
        gate = dict(weekly, id="rolling", role="gate", remaining=10, used=90, windowSeconds=18000, naturalResetAt=NOW+14400)
        data["pools"]["codex"]["limits"].append(gate)
        data["routes"][0]["limits"].append("rolling")
        self.equal(self.checked(data)[0]["pace"], 1.0)
        print("PASS open gate: pace=1, not rolling pace .125")
        monthly = dict(weekly, id="monthly", remaining=10, used=90, windowSeconds=2678400, naturalResetAt=NOW+1339200)
        data["pools"]["codex"]["limits"].append(monthly)
        data["routes"][0]["limits"].append("monthly")
        row = self.checked(data)[0]
        self.equal(row["pace"], .2)
        self.assertEqual(row["binding_limit"], "monthly")
        print("PASS monthly: pace=.2, binding=monthly, actual 31-day duration")

    def test_reference_has_no_production_imports(self):
        tree = ast.parse(Path(REFERENCE.__file__).read_text())
        imported = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                imported.update(alias.name for alias in node.names)
            elif isinstance(node, ast.ImportFrom):
                imported.add(node.module)
        self.assertLessEqual(imported, {"decimal", "fractions", "math"})
        print("PASS oracle independence: only standalone arithmetic or standard-library numeric imports")

    def test_unconditional_weight_without_backing(self):
        data = normalized(fixture(100))
        data["pools"]["codex"]["readerMetadata"] = {"balances": None, "bonuses": None}
        for weight, expected in [(.5, 1.0), (1, 2.0), (1.5, 3.0)]:
            row = self.checked(data, {"codex": {"weight": weight}})[0]
            self.equal(row["score"], expected)
            print(f"PASS no backing: pace2 weight{weight} score{expected}")
        for bad in [0, -1, True, float("inf"), float("nan"), "1"]:
            with self.assertRaises(ValueError):
                ENGINE.rank(data, {"codex": {"weight": bad}})
        for policy in [{"absent": {}}, {"codex": {"resetPolicy": "use"}}, {"codex": {"preference": 9}}]:
            with self.assertRaises(ValueError):
                ENGINE.rank(data, policy)

    def test_blockers_unknowns_and_staleness(self):
        data = normalized(fixture(0, 7200))
        weekly = data["pools"]["codex"]["limits"][0]
        gate = dict(weekly, id="rolling", role="gate", windowSeconds=18000, naturalResetAt=NOW+14400, gateOpensAt=NOW+14400)
        data["pools"]["codex"]["limits"].append(gate)
        data["routes"][0]["limits"].append("rolling")
        row = self.checked(data)[0]
        self.assertEqual((row["pace"], row["score"], row["usage_state"], row["headroom"], row["available_at"]), (0, 0, "out", 0, NOW+14400))
        gate["gateOpensAt"] = None
        self.assertIsNone(self.checked(data)[0]["available_at"])
        weekly.update(remaining=50, used=50)
        self.assertEqual(self.checked(data)[0]["pace"], 0)
        gate["enforced"] = None
        row = self.checked(data)[0]
        self.assertEqual((row["pace"], row["score"], row["usage_state"], row["stale"]), (None, 0, "out", True))
        data = normalized(fixture())
        data["pools"]["codex"]["limits"][0]["observedAt"] = NOW-3601
        self.assertTrue(self.checked(data)[0]["stale"])
        self.equal(self.checked(data)[0]["pace"], 1.0)
        print("PASS blockers: maximum release, unknown release null, closed gate0, unknown pace null, stale measured pace retained")

    def test_complete_order_scope_and_input_independence(self):
        data = normalized(fixture())
        template = data["pools"].pop("codex")
        data["routes"] = []
        for pool, remaining, maker in [("z-session", 15, "same"), ("b-preferred", 3, "other"), ("a-maker", .5, "same"), ("zero", 0, "other"), ("unknown", None, None)]:
            data["pools"][pool] = copy.deepcopy(template)
            limit = data["pools"][pool]["limits"][0]
            limit.update(remaining=remaining, naturalResetAt=NOW+30240, used=None if remaining is None else 100-remaining)
            limit["models"] = ["alpha", "beta"]
            if remaining is None:
                limit["status"] = "missing"
            for model in ["beta", "alpha"]:
                data["routes"].append({"limits": ["weekly"], "maker": maker, "model": model, "pool": pool})
        rows = self.checked(data)
        self.assertEqual([r["pool"] for r in rows], ["z-session", "z-session", "b-preferred", "b-preferred", "a-maker", "a-maker", "unknown", "unknown", "zero", "zero"])
        self.assertEqual([r["model"] for r in rows], ["alpha", "beta"] * 5)
        self.equal([r["score"] for r in rows], [3., 3., .6, .6, .1, .1, 0., 0., 0., 0.])
        data["routes"].reverse()
        self.equal(self.checked(data), rows)
        # Malformed scoped evidence affects only the model drawing that limit.
        limit = dict(data["pools"]["z-session"]["limits"][0], id="scoped", models=["alpha"], status="invalid")
        data["pools"]["z-session"]["limits"].append(limit)
        route = next(r for r in data["routes"] if r["pool"] == "z-session" and r["model"] == "alpha")
        with self.assertRaisesRegex(ValueError, "invalid-route-limit"):
            ENGINE.rank(data)
        route["limits"].append("scoped")
        rows = self.checked(data)
        self.assertEqual((rows[0]["pool"], rows[0]["model"]), ("z-session", "beta"))
        self.equal(rows[0]["score"], 3.0)
        print("PASS complete list: ten routes, zero/unknown retained, pool/model ties, no session/preference/maker ordering, scope isolated")

    def test_frozen_envelopes_and_direct_cli(self):
        saved = fixture(100)
        saved["policy"] = {"codex": {"weight": 1.5}}
        with tempfile.TemporaryDirectory(dir=os.environ["ALLOWANCE_TEST_ROOT"]) as root:
            source = Path(root) / "snapshot.json"
            source.write_text(json.dumps(saved))
            command = [sys.executable, "-I", str(SCRIPTS / "pacing-list.py"), "--snapshot", str(source), "--now", str(NOW)]
            first = subprocess.check_output(command)
            self.assertEqual(first, subprocess.check_output(command))
            result = json.loads(first)
            self.assertEqual(result["capability"], "allowance-preview")
            self.equal(result["entries"], self.checked(normalized(saved), saved["policy"]))
            self.assertEqual(result["entries"][0]["score"], 3)
        saved = json.loads(Path(__file__).with_name("reader-snapshots.json").read_text())
        manifests = json.loads(MANIFEST.read_text()) if MANIFEST else {}
        if MANIFEST:
            self.assertEqual(manifests["inspection"]["policy"], {"codex": {"weight": 1.5}})
            self.assertEqual(manifests["subscription"]["policy"], {"claude": {"weight": .5}})
        for manifest in manifests.values():
            snapshot = {**saved, **manifest}
            self.checked(normalized(snapshot), manifest["policy"])
        print("PASS CLI: pure rank parity, explicit clock, repeated bytes, score3, allowance preview; catalog manifests=" + str(len(manifests)))


if __name__ == "__main__":
    unittest.main(verbosity=2)
