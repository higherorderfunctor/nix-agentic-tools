"""Check ranking from saved Reader captures through normalization.

The Nix check loads handwritten cases from ranking-cases and runs
properties in memory. Synthetic captures use the Reader envelope's JSON shape;
cases translate the vendor-owned status by setting ``enforced`` explicitly.
"""

from __future__ import annotations

import datetime as dt
import json
import sys
import unittest
from pathlib import Path
from typing import Any

from hypothesis import HealthCheck, given, settings, strategies as st
from pydantic import BaseModel

# Loaded before the test classes so per-test @settings inherit it.
settings.register_profile("ranking", database=None, deadline=None, max_examples=60)
settings.load_profile("ranking")

SCRIPTS = Path(sys.argv[1])
sys.path[:0] = [str(SCRIPTS), str(Path(__file__).resolve().parent)]
CASES = Path(sys.argv[2])
import pacing as P
import usage_normalize as N
from reader_fixture import read_cases, reader_stdout

NOW = 1794447300


class RankingCase(BaseModel):
    """Parse one external case at the file boundary, including ranking policy."""

    now: int
    policy: P.RankingPolicy | None = None
    snapshot: dict[str, Any]


def serialized(ranking: P.Ranking) -> dict[str, Any]:
    """Render the NamedTuple result with the same JSON shape its entries use."""
    return {
        "entries": [entry.model_dump(mode="json") for entry in ranking.entries],
        "snapshot": ranking.snapshot.model_dump(mode="json"),
    }


def reader_window(remaining: int, duration: int, reset_in: int | None, *, enforced: bool = True) -> dict[str, Any]:
    """Build one complete Reader window, including its used share."""
    reset = None if reset_in is None else dt.datetime.fromtimestamp(NOW + reset_in, dt.timezone.utc).isoformat()
    return {
        "enforced": enforced,
        "remainingPercent": float(remaining),
        "resetsAt": reset,
        "status": "ok" if enforced else "vendor-disabled",
        "usedPercent": float(100 - remaining),
        "windowSeconds": duration,
    }


def typed_snapshot(pools: dict[str, dict[str, N.LimitSpec]], readers: dict[str, object], routes: list[N.Route]) -> N.Snapshot:
    """Assemble already typed test data without revalidating individual windows."""
    return N.Snapshot(
        pools={name: N.SnapshotRegistration(limits=limits, readerPool="reader") for name, limits in pools.items()},
        readers=readers,
        routes=routes,
    )


def captured_pool(windows: dict[str, object]) -> N.Capture:
    """Build one saved successful Reader command result."""
    return N.Capture(exit=0, stdout=reader_stdout(windows))


def ranked_entry(
    limits: dict[str, N.LimitSpec], windows: dict[str, object]
) -> P.Entry:
    """Normalize one budget capture and rank the sole route."""
    snapshot = typed_snapshot(
        {"budget": limits}, {"budget": captured_pool(windows)}, [N.Route(id="canonical", maker=None, model="served")]
    )
    return P.rank(N.normalize(snapshot, NOW)).entries[0]


class RankingCases(unittest.TestCase):
    """Run literal saved-capture cases and generated ranking properties."""

    def test_handwritten_cases_match_the_whole_ranking_result(self) -> None:
        regressions = {
            "contract-rates": "reset horizons are compared as remaining shares instead of rates",
            "gates-do-not-supply-pace": "positive gate-only routes get pace or zero gates fail to block",
            "idle-baseline-configured": "full idle windows ignore the configured baseline",
            "idle-baseline-default": "omitting policy drops absent or just-elapsed idle resets",
            "unknown-policy-pool-refused": "a misspelled pool weight is silently ignored",
        }
        cases = read_cases(CASES)
        self.assertEqual(cases.keys(), regressions.keys())
        for name, (input_path, expected_path) in cases.items():
            with self.subTest(case=name, regression=regressions[name]):
                case = RankingCase.model_validate_json(input_path.read_text())
                snapshot = N.normalize(N.Snapshot.model_validate(case.snapshot), case.now)
                expected = json.loads(expected_path.read_text())
                if expected_path.name == "expected-error.json":
                    with self.assertRaises(ValueError) as failure:
                        P.rank(snapshot, case.policy)
                    self.assertEqual(str(failure.exception), expected["rankingError"])
                    control = P.rank(snapshot, P.RankingPolicy(weights={"budget": 1}))
                    self.assertEqual([(entry.id, entry.pool) for entry in control.entries], [("canonical", "budget")])
                else:
                    self.assertEqual(serialized(P.rank(snapshot, case.policy)), expected)

    @given(st.sampled_from(["malformed-reset", "null-duration", "numeric-reset"]))
    def test_exhausted_pace_survives_invalid_timing(self, breakage: str) -> None:
        """Wrong: an invalid timer turns a proven zero into unknown non-exhaustion."""
        zero = reader_window(0, 604800, 604800)
        field, value = {
            "malformed-reset": ("resetsAt", "not-a-timestamp"),
            "null-duration": ("windowSeconds", None),
            "numeric-reset": ("resetsAt", NOW + 604800),
        }[breakage]
        zero[field] = value
        entry = ranked_entry(
            {"exhausted": N.LimitSpec(capacity=100, models=["canonical"], role="pace", window="zero")},
            {"zero": zero},
        )
        self.assertEqual((entry.pace, entry.score, entry.state), (0.0, 0.0, "out"))

    @given(st.sampled_from(["invalid", "not-enforced", "stale", "unknown-enforcement", "unresolved-scope", "valid"]))
    def test_positive_unknown_evidence_never_ranks_ready(self, failure: str) -> None:
        """Wrong: invalid, stale, unresolved, or unenforced evidence supplies positive pace."""
        windows = {"7d": reader_window(50, 604800, 302400)}
        if failure == "unknown-enforcement":
            windows["7d"].pop("enforced")
            windows["7d"]["status"] = None
        elif failure == "not-enforced":
            windows["7d"] = reader_window(50, 604800, 302400, enforced=False)
        elif failure == "invalid":
            windows["7d"]["resetsAt"] = "not-a-timestamp"
        elif failure == "stale":
            windows["7d"]["resetsAt"] = "2026-11-11T01:35:00Z"
        elif failure == "unresolved-scope":
            windows["private"] = reader_window(100, 604800, None)
        entry = ranked_entry(
            {"allowance": N.LimitSpec(capacity=100, models=["canonical"], role="pace", window="7d")},
            windows,
        )
        expected = (1.0, 1.0, "ready") if failure == "valid" else (None, 0.0, "out")
        self.assertEqual((entry.pace, entry.score, entry.state), expected)

    # These small draws do not justify a runner-speed gate: the slow-input
    # check has failed CI on a loaded runner.
    @settings(suppress_health_check=[HealthCheck.too_slow])
    @given(
        shares=st.permutations((25, 50)),
        capacities=st.tuples(st.integers(1, 99), st.integers(101, 200)),
    )
    def test_overlapping_paced_windows_use_actual_capacity_and_minimum(
        self, shares: list[int], capacities: tuple[int, int]
    ) -> None:
        """Wrong: a fixed capacity divisor, first limit, or largest rate wins."""
        # Half a window remains. At 25% and 50% allowance the rates are 0.5 and 1.
        windows, limits = {}, {}
        for index, (share, capacity) in enumerate(zip(shares, capacities)):
            key = f"window-{index}"
            windows[key] = reader_window(share, 18000, 9000)
            limits[key] = N.LimitSpec(capacity=capacity, models=["canonical"], role="pace", window=key)
        entry = ranked_entry(limits, windows)
        self.assertEqual((entry.pace, entry.score, entry.state), (0.5, 0.5, "ready"))

    @given(st.permutations(("a", "b", "c")), st.permutations(("covered", "uncovered", "vendor-covered")))
    def test_pool_and_route_permutations_keep_whole_entry_order(self, pools: list[str], routes: list[str]) -> None:
        """Wrong: order changes weighted alternatives, uncovered routes or maker ties."""
        route_values = {
            "covered": N.Route(id="canonical", maker=None, model="served"),
            "vendor-covered": N.Route(id="canonical", maker="vendor", model="served"),
            "uncovered": N.Route(id="uncovered", maker=None, model="other"),
        }
        limit = N.LimitSpec(capacity=100, models=["canonical"], role="pace", window="7d")
        windows = {"7d": reader_window(50, 604800, 302400)}
        capture = captured_pool(windows)
        snapshot = typed_snapshot(
            {name: {"allowance": limit} for name in pools},
            {name: capture for name in pools if name != "a"},
            [route_values[name] for name in routes],
        )
        normalized = N.normalize(snapshot, NOW)
        # An absent Reader still leaves a registered alternative with unresolved scope.
        missing = normalized.pools["a"]
        self.assertFalse(missing.scopeResolved)
        self.assertEqual(
            [(limit.id, limit.status, limit.reason, limit.remaining) for limit in missing.limits],
            [("allowance", "missing", "missing-capture", None)],
        )
        # Rank must not drop or rewrite the source of a failed alternative's reason.
        original = normalized.model_copy(deep=True)
        result = P.rank(normalized, P.RankingPolicy(weights={"b": 0, "c": 2}))
        self.assertEqual(result.snapshot, original)
        self.assertEqual(
            [(e.id, e.model, e.pool, e.maker, e.pace, e.score, e.state) for e in result.entries],
            [
                ("canonical", "served", "c", None, 1.0, 2.0, "ready"),
                ("canonical", "served", "c", "vendor", 1.0, 2.0, "ready"),
                ("canonical", "served", "b", None, 1.0, 0.0, "ready"),
                ("canonical", "served", "b", "vendor", 1.0, 0.0, "ready"),
                ("uncovered", "other", None, None, None, 0.0, "out"),
                ("canonical", "served", "a", None, None, 0.0, "out"),
                ("canonical", "served", "a", "vendor", None, 0.0, "out"),
            ],
        )


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]], verbosity=2)
