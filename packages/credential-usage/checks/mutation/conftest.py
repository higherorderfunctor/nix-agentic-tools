# pyright: strict
# cspell:ignore logreport nodeid
"""Record the test × mutant observations that mutmut's per-mutant totals omit."""

import os
from pathlib import Path

import pytest


def pytest_runtest_logreport(report: pytest.TestReport) -> None:
    """Append each executed test outcome, retaining setup errors separately from kills."""
    fault = os.environ.get("NAMED_FAULT") or os.environ.get("MUTANT_UNDER_TEST", "")
    if fault in ("", "stats", "fail", "list_all_tests") or (report.when != "call" and not report.failed):
        return
    case = report.context.kwargs.get("case") if isinstance(report, pytest.SubtestReport) else None
    fixture = case if isinstance(case, str) else ""
    with Path(os.environ["MATRIX_FILE"]).open("a") as stream:
        print(fault, report.nodeid, fixture, report.when, report.outcome, sep="\t", file=stream)
