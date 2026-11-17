"""Check ranking from saved Reader captures through normalization.

The Nix check loads handwritten cases from ranking-cases and runs three
properties in memory. Synthetic captures use the Reader envelope's JSON shape;
cases translate the vendor-owned status by setting ``enforced`` explicitly.
"""

from __future__ import annotations

import datetime as dt
from itertools import permutations
import runpy
import sys
import types
import unittest
from pathlib import Path
from typing import Any

from hypothesis import given, settings, strategies as st
from pydantic import BaseModel, JsonValue, RootModel

SCRIPTS = Path(sys.argv[1])
CASES = Path(sys.argv[2])
P = types.SimpleNamespace(**runpy.run_path(str(SCRIPTS / "pacing.py")))
N = P.normalizer
NOW = 1794447300


class RankingCase(BaseModel):
    """Parse one external case at the file boundary, including ranking policy."""

    now: int
    policy: P.RankingPolicy | None = None
    snapshot: dict[str, Any]


class RefusedRanking(BaseModel):
    """Name the ranking boundary error a handwritten case expects."""

    rankingError: str


class ExpectedOutput(RootModel[JsonValue]):
    """Keep the expected ranking literally, including missing fields."""


def read_expected(path: Path) -> ExpectedOutput | RefusedRanking:
    """Parse exactly one expected file, separating normal and refused outcomes."""
    output_path = path / "expected.json"
    error_path = path / "expected-error.json"
    if output_path.exists() == error_path.exists():
        raise ValueError(f"{path.name}: requires exactly one expected file")
    if error_path.exists():
        return RefusedRanking.model_validate_json(error_path.read_text())
    return ExpectedOutput.model_validate_json(output_path.read_text())


def load_cases() -> list[tuple[str, RankingCase, ExpectedOutput | RefusedRanking]]:
    """Parse each handwritten input and outcome once in stable directory order."""
    paths = sorted(path for path in CASES.iterdir() if path.is_dir())
    return [(path.name, RankingCase.model_validate_json((path / "input.json").read_text()), read_expected(path)) for path in paths]


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
        pools={name: N.Registration(limits=limits, readerPool="reader") for name, limits in pools.items()},
        readers=readers,
        routes=routes,
    )


def captured_pool(windows: dict[str, object]) -> N.Capture:
    """Build one saved successful Reader command result."""
    envelope = N.Envelope(pool="reader", windows=windows)
    return N.Capture(exit=0, stdout=envelope.model_dump_json())


def ranked_entry(
    limits: dict[str, N.LimitSpec], windows: dict[str, object] | None
) -> P.Entry:
    """Normalize one budget capture, or its absence, and rank the sole route."""
    capture = None if windows is None else captured_pool(windows)
    snapshot = typed_snapshot(
        {"budget": limits}, {"budget": capture} if capture else {}, [N.Route(id="canonical", maker=None, model="served")]
    )
    return P.rank(N.normalize(snapshot, NOW)).entries[0]


class RankingCases(unittest.TestCase):
    """Run literal saved-capture cases and generated ranking properties."""

    def test_handwritten_cases_match_the_whole_ranking_result(self) -> None:
        """Wrong: any changed output field, retained snapshot field, or dropped route passes."""
        cases = load_cases()
        self.assertTrue(cases, "ranking case directory is empty")
        for name, case, expected in cases:
            with self.subTest(case=name):
                if isinstance(expected, RefusedRanking):
                    with self.assertRaises(ValueError) as failure:
                        P.rank(N.normalize(N.Snapshot.model_validate(case.snapshot), case.now), case.policy)
                    self.assertEqual(str(failure.exception), expected.rankingError)
                    continue
                ranking = P.rank(N.normalize(N.Snapshot.model_validate(case.snapshot), case.now), case.policy)
                self.assertEqual(serialized(ranking), expected.root)

    @given(st.sampled_from(["malformed-reset", "numeric-reset", "text-duration", "null-duration"]))
    def test_exhausted_pace_survives_invalid_timing(self, breakage: str) -> None:
        """Wrong: an invalid timer turns a proven zero into unknown non-exhaustion."""
        zero = reader_window(0, 604800, 604800)
        zero["resetsAt"] = "not-a-timestamp"
        if breakage == "numeric-reset":
            zero["resetsAt"] = NOW + 604800
        elif breakage == "text-duration":
            zero["windowSeconds"] = "one-week"
        elif breakage == "null-duration":
            zero["windowSeconds"] = None
        entry = ranked_entry(
            {"exhausted": N.LimitSpec(capacity=100, models=["canonical"], role="pace", window="zero")},
            {"zero": zero},
        )
        self.assertEqual((entry.pace, entry.score, entry.state), (0.0, 0.0, "out"))

    @given(st.sampled_from(["missing", "invalid", "stale", "unresolved-scope", "unknown-enforcement", "not-enforced"]))
    def test_positive_unknown_evidence_never_ranks_ready(self, failure: str) -> None:
        """Wrong: missing, stale, unresolved, or unenforced evidence supplies positive pace."""
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
            None if failure == "missing" else windows,
        )
        self.assertEqual((entry.pace, entry.score, entry.state), (None, 0.0, "out"))

    @given(
        rates=st.sampled_from([order[:2] for order in permutations((0.2, 0.5, 1.0))]),
        capacities=st.tuples(st.integers(1, 200), st.integers(1, 200)).filter(
            lambda values: 100 not in values
        ),
        shares=st.tuples(st.sampled_from([10, 20, 25, 50, 80]), st.sampled_from([10, 20, 25, 50, 80])),
        resets=st.tuples(st.sampled_from([1800, 3600, 7200]), st.sampled_from([1800, 3600, 7200])),
    )
    def test_overlapping_paced_windows_use_actual_capacity_and_minimum(
        self,
        rates: tuple[float, float],
        capacities: tuple[int, int],
        shares: tuple[int, int],
        resets: tuple[int, int],
    ) -> None:
        """Wrong: a fixed capacity divisor or the largest paced limit supplies the rate."""
        windows, limits = {}, {}
        for index, (rate, capacity, share, reset) in enumerate(zip(rates, capacities, shares, resets)):
            window = f"window-{index}"
            windows[window] = reader_window(share, int(rate * reset * 100 / share), reset)
            limits[window] = N.LimitSpec(capacity=capacity, models=["canonical"], role="pace", window=window)
        entry = ranked_entry(limits, windows)
        self.assertAlmostEqual(entry.pace, min(rates))
        self.assertAlmostEqual(entry.score, min(rates))
        self.assertEqual(entry.state, "ready")

    @given(
        st.sampled_from([tuple(order) for order in permutations(("a", "b", "c"))]),
        st.sampled_from([tuple(order) for order in permutations(("covered", "vendor-covered", "uncovered"))]),
    )
    def test_pool_and_route_permutations_keep_whole_entry_order(self, pools: list[str], routes: list[str]) -> None:
        """Wrong: input order changes weighted alternatives, uncovered routes, or ties."""
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
        result = P.rank(N.normalize(snapshot, NOW), P.RankingPolicy(weights={"b": 0, "c": 2}))
        self.assertEqual(
            [(entry.pool, entry.maker, entry.score, entry.state) for entry in result.entries],
            [
                ("c", None, 2.0, "ready"),
                ("c", "vendor", 2.0, "ready"),
                ("b", None, 0.0, "ready"),
                ("b", "vendor", 0.0, "ready"),
                (None, None, 0.0, "out"),
                ("a", None, 0.0, "out"),
                ("a", "vendor", 0.0, "out"),
            ],
        )


if __name__ == "__main__":
    settings.register_profile("ranking", database=None, deadline=None, max_examples=60)
    settings.load_profile("ranking")
    unittest.main(argv=[sys.argv[0]], verbosity=2)
