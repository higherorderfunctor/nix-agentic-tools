"""Check ranking from typed Reader inputs through normalization to weighted entries.

The owner check runs generated properties against independent rational arithmetic.
Literal cases pin the allowance contract; synthetic collection covers failure
without credentials, live Readers or an inspection command.
"""

import copy
import datetime as dt
from pathlib import Path
import runpy
import subprocess
import sys
import types
import unittest
from unittest.mock import patch

from hypothesis import given, settings, strategies as st
from pydantic import ValidationError

# The owner check supplies its packaged scripts; no package installation is needed.
SCRIPTS = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / "scripts"
P = types.SimpleNamespace(**runpy.run_path(str(SCRIPTS / "pacing.py")))
N = P.normalizer
C = types.SimpleNamespace(**runpy.run_path(str(SCRIPTS / "usage-collect.py")))
REFERENCE = runpy.run_path(str(Path(__file__).with_name("reference.py")))["score"]
settings.register_profile("ranking", database=None, deadline=None, max_examples=60)
settings.load_profile("ranking")
NOW = "2026-11-12T01:35:00Z"
EPOCH = 1794447300


def iso(seconds):
    """Render synthetic Reader timestamps in the producer's offset-bearing format."""
    return dt.datetime.fromtimestamp(seconds, dt.timezone.utc).isoformat()


def snapshot(rows):
    """Build typed registrations and captures from role, share, duration and time left."""
    limits, windows = {}, {}
    for i, (role, share, duration, left) in enumerate(rows):
        key = str(i)
        limits[key] = N.LimitSpec(capacity=100, models=["canonical"], role=role,
                                 unit="percentagePoint", window=key)
        windows[key] = N.Window(remainingPercent=share, usedPercent=100 - share,
                               windowSeconds=duration, resetsAt=iso(EPOCH + left), status="active").model_dump(mode="json")
    envelope = N.Envelope(account=N.Account(auth_index=None, name=None, plan=None), pool="reader", windows=windows)
    return N.Snapshot(pools={"budget": N.Registration(readerPool="reader", limits=limits)},
                      readers={"budget": N.Capture(exit=0, finishedAt=NOW, data=envelope.model_dump(mode="json", exclude_unset=True))},
                      routes=[N.Route(id="canonical", maker=None, model="served")], runtime="offline").model_dump(mode="json", exclude_unset=True)


def ranked(raw, weights=None):
    """Parse the external snapshot and weights once before calling the typed engine."""
    return P.rank(N.normalize(raw, NOW), P.Weights.model_validate(weights or {}))


@st.composite
def paced_rows(draw):
    """Generate valid paced limits across shares, native durations and future resets."""
    duration = draw(st.integers(1, 2678400))
    return ("pace", draw(st.integers(1, 100)), duration, draw(st.integers(1, duration)))


class AllowanceTests(unittest.TestCase):
    def test_literal_arithmetic(self):
        """Reject clipped, weekly-assumed or elapsed-fraction arithmetic."""
        cases = [
            ([("pace", 50, 604800, 302400)], 1.0),
            ([("pace", 50, 604800, 302400), ("gate", 1, 18000, 9000)], 1.0),
            ([("pace", 100, 604800, 302400)], 2.0),
            ([("pace", 50, 604800, 3600)], 84.0),
            ([("pace", 10, 2678400, 1339200)], 0.2),
        ]
        for rows, expected in cases:
            with self.subTest(rows=rows):
                entry = ranked(snapshot(rows)).entries[0]
                self.assertEqual((entry.pace, entry.score, entry.state), (expected, expected, "ready"))

    @given(st.lists(paced_rows(), min_size=1, max_size=6), st.integers(0, 100))
    def test_weighted_pace_matches_independent_rational_oracle(self, rows, weight):
        """Reject averaging limits, clipping rates and conditional preference weights."""
        entry = ranked(snapshot(rows), {"budget": weight}).entries[0]
        oracle_rows = [(role, 100, share, duration, left) for role, share, duration, left in rows]
        self.assertAlmostEqual(entry.pace, float(REFERENCE(oracle_rows)))
        self.assertAlmostEqual(entry.score, float(REFERENCE(oracle_rows, weight)))
        self.assertEqual(entry.state, "ready")

    @given(paced_rows(), st.integers(1, 100))
    def test_open_gate_never_supplies_or_changes_pace(self, row, share):
        """Reject treating a gate's positive allowance as a rate, including gate-only offers."""
        gate = ("gate", share, 18000, 9000)
        alone = ranked(snapshot([gate])).entries[0]
        self.assertEqual((alone.pace, alone.score, alone.state), (None, 0, "out"))
        self.assertEqual(ranked(snapshot([row, gate])).entries[0], ranked(snapshot([row])).entries[0])
        raw = snapshot([row, gate])
        raw["readers"]["budget"]["data"]["windows"]["1"]["resetsAt"] = None
        self.assertEqual(ranked(raw).entries[0], ranked(snapshot([row])).entries[0])

    @given(st.sampled_from(["pace", "gate"]), st.sampled_from([None, "private-invalid", iso(EPOCH), iso(EPOCH + 1)]))
    def test_exhaustion_blocks_even_with_invalid_timing(self, role, reset):
        """Reject loss of independent paced zero or readiness through any closed gate."""
        raw = snapshot([("pace", 50, 604800, 302400), (role, 0, 100, 1)])
        raw["readers"]["budget"]["data"]["windows"]["1"]["resetsAt"] = reset
        entry = ranked(raw).entries[0]
        self.assertEqual((entry.state, entry.score), ("out", 0))
        if role == "pace":
            self.assertEqual(entry.pace, 0)

    @given(st.sampled_from(["missing", "stale", "invalid", "enforcement", "scope", "idle"]))
    def test_incomplete_evidence_cannot_establish_positive_pace(self, failure):
        """Reject positive pace from unknown scope, enforcement, missing resets or bad captures."""
        raw = snapshot([("pace", 50, 604800, 302400)])
        capture = raw["readers"]["budget"]
        window = capture["data"]["windows"]["0"]
        if failure == "missing":
            capture["data"]["windows"].clear()
        elif failure == "stale":
            window["resetsAt"] = iso(EPOCH)
        elif failure == "invalid":
            window["windowSeconds"] = "private-duration"
        elif failure == "enforcement":
            window["status"] = "private-status"
        elif failure == "scope":
            capture["data"]["windows"]["private-scope"] = {}
        else:
            window.update(remainingPercent=100, usedPercent=0, resetsAt=None)
        entry = ranked(raw).entries[0]
        self.assertEqual((entry.pace, entry.score, entry.state), (None, 0, "out"))

    def test_flat_weights_validate_shape_and_refuse_overflow(self):
        """Reject malformed weights, unknown pools and scores that are not finite."""
        raw = snapshot([("pace", 50, 604800, 302400)])
        self.assertEqual(ranked(snapshot([("pace", 100, 604800, 302400)]), {"budget": 1.5}).entries[0].score, 3)
        self.assertEqual(ranked(raw).entries[0].score, 1)
        self.assertEqual(ranked(raw, {"budget": 0}).entries[0].state, "ready")
        for bad in [True, -1, float("inf"), float("nan"), "1", {}, {"weight": 1}]:
            with self.subTest(bad=bad), self.assertRaises(ValidationError):
                P.Weights.model_validate({"budget": bad})
        with self.assertRaises(ValueError):
            ranked(raw, {"absent": 1})
        raw = snapshot([("pace", 50, 604800, 3600)])
        with self.assertRaises(ValidationError):
            ranked(raw, {"budget": 1e308})

    @given(st.permutations(["a", "b", "c"]), st.permutations([0, 1, 2]))
    def test_overlap_scope_and_weighted_order_ignore_input_permutations(self, pools, routes):
        """Reject first-credential attribution, unstable ties, scope expansion and dropped routes."""
        raw = snapshot([("pace", 50, 604800, 302400)])
        raw["pools"] = {key: copy.deepcopy(raw["pools"]["budget"]) for key in pools}
        capture = raw["readers"]["budget"]
        raw["readers"] = {key: copy.deepcopy(capture) for key in pools}
        raw["readers"]["a"]["exit"] = 9
        offers = [dict(id="canonical", model="served", maker=maker) for maker in [None, "maker"]]
        offers.append(dict(id="uncovered", model="uncovered", maker=None))
        raw["routes"] = [offers[i] for i in routes]
        result = ranked(raw, {"b": 0, "c": 2})
        self.assertEqual([(e.pool, e.maker, e.score, e.state) for e in result.entries], [
            ("c", None, 2, "ready"), ("c", "maker", 2, "ready"),
            ("b", None, 0, "ready"), ("b", "maker", 0, "ready"),
            (None, None, 0, "out"), ("a", None, 0, "out"), ("a", "maker", 0, "out"),
        ])
        self.assertEqual([r.model_dump() for r in result.snapshot.routes], raw["routes"])

    def test_failed_collection_retains_routes_and_safe_diagnostics_through_ranking(self):
        """Reject route loss or leaked process output across collection, normalization and ranking."""
        raw = snapshot([("pace", 50, 604800, 302400)])
        raw["pools"]["budget"]["command"] = "synthetic-reader"
        manifest = C.Manifest.model_validate({**raw, "readers": {}})
        def fail(argv, **kwargs):
            return subprocess.CompletedProcess(argv, 9, "private-stdout", "private-stderr")
        with patch.object(C.planner.collect.__globals__["time"], "sleep"):
            captured = C.collect(manifest, NOW, "/synthetic/bash", run=fail,
                                 clock=lambda: dt.datetime.fromisoformat(NOW))
        observed = C.normalizer.normalize(captured, NOW)
        result = P.rank(observed)
        self.assertIs(result.snapshot, observed)
        self.assertEqual([r.model_dump() for r in observed.routes], raw["routes"])
        self.assertEqual((result.entries[0].pace, result.entries[0].score), (None, 0))
        self.assertEqual(observed.diagnostics.count({"pool": "budget", "reason": "exit-nonzero", "exitStatus": 9}), 1)
        self.assertNotIn("private-", observed.model_dump_json())


if __name__ == "__main__":
    unittest.main()
