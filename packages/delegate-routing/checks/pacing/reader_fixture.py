"""Serialize synthetic Reader stdout and discover observation and ranking cases.

Register each case name and the regression it catches in the owning runner's
regressions table.
"""

import json
from pathlib import Path


def reader_stdout(windows: dict[str, object]) -> str:
    """Use the shell Readers' full envelope so tests can pass malformed windows to the parser."""
    return json.dumps({
        "account": {"auth_index": None, "name": "fixture", "plan": None},
        "balances": [], "bonuses": [], "pool": "reader", "windows": windows,
    })


def read_cases(directory: Path) -> dict[str, tuple[Path, Path]]:
    """Find the input and sole expected outcome for each named case."""
    cases = {}
    for path in sorted(directory.iterdir()):
        if not path.is_dir():
            continue
        expected = path / "expected.json"
        error = path / "expected-error.json"
        if expected.exists() == error.exists():
            raise ValueError(f"{path.name}: requires exactly one expected file")
        cases[path.name] = (path / "input.json", error if error.exists() else expected)
    return cases
