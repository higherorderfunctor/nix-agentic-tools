"""Compare handwritten pacing cases with the whole normalizer result.

The Nix observation check runs this file with its script and case directories.
Each case's JSON is parsed once at this boundary; only the two properties below
construct inputs in memory.
"""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path
from typing import Any

from hypothesis import example, given, settings, strategies as st
from pydantic import BaseModel, ValidationError

SCRIPTS = Path(sys.argv[1])
sys.path[:0] = [str(SCRIPTS), str(Path(__file__).resolve().parent)]
CASES = Path(sys.argv[2])
import usage_normalize as N
from reader_fixture import read_cases, reader_stdout

NOW = 1794447300


class Case(BaseModel):
    """Carry one saved snapshot to the normalizer."""

    now: int
    snapshot: Any


def snapshot_with_windows(limits: dict[str, N.LimitSpec], windows: dict[str, object] | None) -> N.Snapshot:
    """Bind configured windows to a saved capture, or omit the failed capture."""
    readers = {} if windows is None else {"budget": N.Capture(exit=0, stdout=reader_stdout(windows))}
    return N.Snapshot(
        pools={"budget": N.SnapshotRegistration(readerPool="reader", limits=limits)},
        readers=readers,
        routes=[N.Route(id="canonical-a", maker=None, model="served-fable")],
    )

class WholeOutcomes(unittest.TestCase):
    """Check complete normalizer results and properties that span many inputs."""

    def test_handwritten_cases_match_the_complete_normalizer_result(self) -> None:
        regressions = {
            "duplicate-window-refuses-configuration": "two limits claim one Reader window",
            "exhausted-window-survives-broken-timing": "a malformed duration hides a recorded zero",
            "expired-reset-is-stale": "an expired reset erases a proven zero or implies a refill",
            "invalid-envelope-keeps-limit": "a structurally invalid Reader result loses the limit slot",
            "invalid-json-keeps-limit": "malformed JSON is mislabeled as an invalid envelope",
            "missing-reset-role-contrast": "gate and pace evidence with no reset are treated alike",
            "missing-window-keeps-limit": "a valid Reader missing the registered window loses the limit slot",
            "nonzero-exit-keeps-limit": "a failed Reader supplies allowance from its stdout",
            "pool-mismatch-keeps-limit": "another pool's Reader supplies evidence",
            "positive-broken-window-becomes-unknown": "an invalid reset still supplies positive allowance",
            "unknown-route-refuses-configuration": "a served model name stands in for the canonical route id",
            "unregistered-window-breaks-scope": "an unexplained extra window leaves scope resolved",
            "valid-window-enforced-states": "unknown or invalid enforcement becomes known and enforced",
        }
        cases = read_cases(CASES)
        self.assertEqual(cases.keys(), regressions.keys())
        for name, (input_path, expected_path) in cases.items():
            with self.subTest(case=name, regression=regressions[name]):
                case = Case.model_validate_json(input_path.read_text())
                expected = json.loads(expected_path.read_text())
                if expected_path.name == "expected-error.json":
                    with self.assertRaises(ValidationError) as failure:
                        N.Snapshot.model_validate(case.snapshot)
                    location = ("pools", "budget") if name == "duplicate-window-refuses-configuration" else ()
                    self.assertEqual(
                        [(issue["loc"], issue["type"], str(issue.get("ctx", {}).get("error")))
                         for issue in failure.exception.errors()],
                        [(location, "value_error", expected["validationError"])],
                    )
                    limits = case.snapshot["pools"]["budget"]["limits"]
                    if name == "duplicate-window-refuses-configuration":
                        limits["second"]["window"] = "5h"
                    else:
                        limits["allowance"]["models"] = ["canonical-a"]
                    control = N.normalize(N.Snapshot.model_validate(case.snapshot), case.now)
                    self.assertEqual([item.id for item in control.pools["budget"].limits], sorted(limits))
                else:
                    actual = N.normalize(N.Snapshot.model_validate(case.snapshot), case.now)
                    self.assertEqual(actual.model_dump(mode="json"), expected)

    def test_reader_requires_balances_and_bonuses_arrays(self) -> None:
        """Wrong: a missing or object-valued collection supplies usable Reader evidence."""
        fixtures = Path(__file__).resolve().parent / "invalid-reader-arrays"
        expected = json.loads((fixtures / "expected.json").read_text())
        invalid = json.loads((fixtures / "input.json").read_text())
        self.assertEqual(set(invalid), {"balances-missing", "balances-object", "bonuses-missing", "bonuses-object"})
        registration = N.SnapshotRegistration(readerPool="reader", limits={})
        for name, stdout in invalid.items():
            with self.subTest(case=name):
                evidence = N.read_capture({"exit": 0, "stdout": stdout}, registration)
                self.assertEqual(evidence._asdict(), expected)
        evidence = N.read_capture({"exit": 0, "stdout": reader_stdout({})}, registration)
        self.assertIsNone(evidence.reason)

    @example(remaining=0, breakage="quantities-total-not-100")
    @given(
        remaining=st.integers(min_value=0, max_value=100),
        breakage=st.sampled_from(
            ["negative-duration", "zero-duration", "text-duration", "quantities-total-not-100"]
        ),
    )
    def test_broken_window_keeps_a_reported_zero_and_never_a_positive_allowance(
        self, remaining: int, breakage: str
    ) -> None:
        """Wrong: a broken window leaks a positive allowance, or loses a reported zero."""
        window: dict[str, object] = {
            "status": None,
            "remainingPercent": float(remaining),
            "usedPercent": float(100 - remaining),
            "resetsAt": "2026-11-19T01:35:00Z",
            "windowSeconds": 604800.0,
        }
        if breakage == "quantities-total-not-100":
            # Shift used by one so the two shares total 99 or 101.
            window["usedPercent"] = float(99 - remaining) if remaining < 100 else 1.0
        else:
            durations = {"negative-duration": -604800.0, "zero-duration": 0.0, "text-duration": "not-a-duration"}
            window["windowSeconds"] = durations[breakage]
        limits = {"allowance": N.LimitSpec(capacity=40.0, models=["canonical-a"], role="pace", window="7d")}
        result = N.normalize(snapshot_with_windows(limits, {"7d": window}), NOW)
        reason = "invalid-window: window" if breakage == "quantities-total-not-100" else "invalid-window: windowSeconds"
        self.assertEqual(
            [(item.id, item.status, item.reason, item.remaining) for item in result.pools["budget"].limits],
            [("allowance", "invalid", reason, 0 if remaining == 0 else None)],
        )

    @given(
        names=st.lists(
            st.sampled_from(["alpha", "beta", "gamma", "delta"]),
            min_size=1,
            max_size=4,
            unique=True,
        ),
        capture_fails=st.booleans(),
    )
    def test_every_configured_limit_keeps_its_slot_when_capture_fails(
        self, names: list[str], capture_fails: bool
    ) -> None:
        """Wrong: a failed Reader drops configured limit slots or reorders them."""
        limits = {
            name: N.LimitSpec(
                capacity=10.0,
                models=["canonical-a"],
                role="pace",
                window=f"window:{name}",
            )
            for name in names
        }
        windows = {
            spec.window: {
                "status": None,
                "remainingPercent": 50.0,
                "usedPercent": 50.0,
                "resetsAt": "2026-11-19T01:35:00Z",
                "windowSeconds": 604800.0,
            }
            for spec in limits.values()
        }
        snapshot = snapshot_with_windows(limits, None if capture_fails else windows)
        result = N.normalize(snapshot, NOW)
        self.assertEqual(
            [(item.id, item.reason) for item in result.pools["budget"].limits],
            [(name, "missing-capture" if capture_fails else "enforced-unknown") for name in sorted(names)],
        )


if __name__ == "__main__":
    settings.register_profile("offline", database=None, deadline=None, max_examples=60)
    settings.load_profile("offline")
    unittest.main(argv=[sys.argv[0]], verbosity=2)
