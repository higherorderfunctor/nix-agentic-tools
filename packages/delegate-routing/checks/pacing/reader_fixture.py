"""Serialize synthetic Reader stdout for the observation and ranking suites."""

import json


def reader_stdout(windows: dict[str, object]) -> str:
    """Use the shell Readers' full envelope so tests can pass malformed windows to the parser."""
    return json.dumps({
        "account": {"auth_index": None, "name": "fixture", "plan": None},
        "balances": [], "bonuses": [], "pool": "reader", "windows": windows,
    })
