"""Compare handwritten pacing cases with the whole normalizer result.

The Nix observation check runs this file with its script and case directories.
Each case's JSON is parsed once at this boundary; only the two properties below
construct inputs in memory.
"""

from __future__ import annotations

import runpy
import sys
import types
import unittest
from pathlib import Path
from typing import Any

from hypothesis import example, given, settings, strategies as st
from pydantic import BaseModel, JsonValue, RootModel, ValidationError

SCRIPTS = Path(sys.argv[1])
CASES = Path(sys.argv[2])
N = types.SimpleNamespace(**runpy.run_path(str(SCRIPTS / "usage-normalize.py")))
NOW = 1794447300


class RefusedConfiguration(BaseModel):
    """Name the configuration error a handwritten case expects."""

    validationError: str


class ExpectedOutput(RootModel[JsonValue]):
    """Preserve the expected JSON literally, including missing and extra keys."""


class Case(BaseModel):
    """Carry one saved snapshot to the normalizer."""

    now: int
    snapshot: Any


def read_expected(path: Path) -> ExpectedOutput | RefusedConfiguration:
    """Parse exactly one expected file, keeping normal and error outcomes separate."""
    output_path = path / "expected.json"
    error_path = path / "expected-error.json"
    if output_path.exists() == error_path.exists():
        raise ValueError(f"{path.name}: requires exactly one expected file")
    if error_path.exists():
        return RefusedConfiguration.model_validate_json(error_path.read_text())
    return ExpectedOutput.model_validate_json(output_path.read_text())


def load_cases() -> list[tuple[str, Case, ExpectedOutput | RefusedConfiguration]]:
    """Parse each input and expected outcome once, in a stable order."""
    paths = sorted(path for path in CASES.iterdir() if path.is_dir())
    return [
        (
            path.name,
            Case.model_validate_json((path / "input.json").read_text()),
            read_expected(path),
        )
        for path in paths
    ]


def snapshot_with_windows(windows: dict[str, object]) -> N.Snapshot:
    """Build the smallest registered snapshot that carries the tested windows."""
    envelope = N.Envelope(pool="reader", windows=windows)
    captures = {"budget": N.Capture(exit=0, stdout=envelope.model_dump_json())}
    return N.Snapshot(
        pools={
            "budget": N.Registration(
                readerPool="reader",
                limits={
                    "allowance": N.LimitSpec(
                        capacity=40.0,
                        models=["canonical-a"],
                        role="pace",
                        window="7d",
                    )
                },
            )
        },
        readers=captures,
        routes=[N.Route(id="canonical-a", maker=None, model="served-fable")],
    )


class WholeOutcomes(unittest.TestCase):
    """Check complete normalizer results and properties that span many inputs."""

    def test_handwritten_cases_match_the_complete_normalizer_result(self) -> None:
        """Wrong: any changed or omitted output field passes unnoticed."""
        cases = load_cases()
        self.assertTrue(cases, "pacing case directory is empty")
        for name, case, expected in cases:
            with self.subTest(case=name):
                if isinstance(expected, RefusedConfiguration):
                    with self.assertRaises(ValidationError) as failure:
                        N.Snapshot.model_validate(case.snapshot)
                    self.assertIn(expected.validationError, str(failure.exception))
                    continue
                actual = N.normalize(
                    N.Snapshot.model_validate(case.snapshot), case.now
                ).model_dump(mode="json")
                self.assertEqual(actual, expected.root)

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
        result = N.normalize(snapshot_with_windows({"7d": window}), NOW)
        observation = result.pools["budget"].limits[0]
        self.assertEqual(observation.status, "invalid")
        self.assertEqual(observation.remaining, 0 if remaining == 0 else None)

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
        """Wrong: a failed Reader drops configured limits from the result."""
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
                "remainingPercent": 50.0,
                "usedPercent": 50.0,
                "resetsAt": "2026-11-19T01:35:00Z",
                "windowSeconds": 604800.0,
            }
            for spec in limits.values()
        }
        snapshot = N.Snapshot(
            pools={"budget": N.Registration(readerPool="reader", limits=limits)},
            readers={} if capture_fails
            else {
                "budget": N.Capture(
                    exit=0,
                    stdout=N.Envelope(pool="reader", windows=windows).model_dump_json(),
                )
            },
            routes=[N.Route(id="canonical-a", maker=None, model="served-fable")],
        )
        result = N.normalize(snapshot, NOW)
        self.assertEqual(
            [observation.id for observation in result.pools["budget"].limits],
            sorted(names),
        )


if __name__ == "__main__":
    settings.register_profile("offline", database=None, deadline=None, max_examples=60)
    settings.load_profile("offline")
    unittest.main(argv=[sys.argv[0]], verbosity=2)
