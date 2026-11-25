"""Replay one stalled vendor request through the Claude Reader under the deadline its runner sets.

The Nix check passes the conformance suite and imports the installed modules.
"""

from datetime import UTC, datetime
import json
import os
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from urllib3.exceptions import ReadTimeoutError
from urllib3.response import HTTPResponse

from credential_usage.transport import DEADLINE_VARIABLE
from claude_code.usage import cli
from claude_code.usage.claude import PROFILE_URL, USAGE_URL

CHECKOUT = Path(__file__).resolve().parents[3]
PAIR = Path(os.environ.get("USAGE_PAIR") or CHECKOUT / "claude-code" / "usage" / "cases")
SUITE = Path(os.environ.get("USAGE_SUITE") or CHECKOUT / "credential-usage" / "checks" / "conformance")
sys.path.insert(0, str(SUITE))

from suite import Pair, Replay, ScriptedNetwork, captured_stream, case_environment

DEADLINE = 5
MARGIN = 0.5
FULL_BUDGET = DEADLINE - MARGIN
CASE = "grant-optional-terms"
# Each transport sends this many requests before the one the test stalls.
BEFORE_PROFILE = {"direct": 1, "cpa": 2}
BEFORE_USAGE = {"direct": 0, "cpa": 1}


class DeadlineTests(unittest.TestCase):
    """A stalled request costs the timeout it was given; the clock then shows whether the Reader survived."""

    def replay(self, transport: str, stalled_url: str) -> tuple[int | None, str, str, list[float], int]:
        """Run the Reader as the suite does, then discard its output once the runner would have killed it."""
        pair = Pair.read(PAIR)
        case = pair.cases[f"{CASE}/{transport}"]
        replay = Replay.for_case(pair.inputs, case)
        now = [0.0]
        timeouts: list[float] = []
        network = ScriptedNetwork(pair.inputs.now, replay.replies, replay.masks)
        answer = network.request

        def answering_or_stalling(method: str, url: str, *, timeout: float = 0, **settings: object) -> HTTPResponse:
            """Record the request, then stall instead of answering the request the test selected."""
            response = answer(method, url, **settings)
            timeouts.append(timeout)
            forwarded = json.loads(settings["body"])["url"] if settings.get("body") is not None else url
            if forwarded == stalled_url:
                now[0] += timeout
                raise ReadTimeoutError(None, url, "stalled reply")
            return response

        with TemporaryDirectory() as tmp:
            settings = case.scenario.env | {DEADLINE_VARIABLE: str(DEADLINE)}
            env = case_environment(Path(tmp), pair.inputs.executables, settings, replay.credentials)
            monotonic = lambda: now[0]
            with (
                patch.dict(os.environ, env, clear=True),
                patch("urllib3.request", answering_or_stalling),
                patch("credential_usage.transport.time", SimpleNamespace(monotonic=monotonic), create=True),
                captured_stream(1) as stdout,
                captured_stream(2) as stderr,
            ):
                status = cli.main(env, lambda: datetime.now(UTC))
                stdout.seek(0)
                stderr.seek(0)
                out, err = stdout.read(), stderr.read()
        if now[0] > DEADLINE:
            return None, "", "", timeouts, len(network.requests)
        return status, out, err, timeouts, len(network.requests)

    def test_stalled_optional_read_leaves_credits_unknown_and_keeps_windows(self) -> None:
        """128. A profile request that outlasts the deadline lets the runner kill the Reader before it prints."""
        for transport, sent_before in BEFORE_PROFILE.items():
            with self.subTest(transport=transport):
                status, out, err, timeouts, sent = self.replay(transport, str(PROFILE_URL))
                self.assertEqual(status, 0, "the runner killed the Reader at its deadline")
                self.assertEqual((err, sent), ("", sent_before + 1))
                self.assertEqual(timeouts, [FULL_BUDGET] * (sent_before + 1))
                result = json.loads(out)
                self.assertEqual(result["windows"], Pair.read(PAIR).cases[f"{CASE}/{transport}"].expected.result["windows"])
                self.assertEqual(result["balances"], [])
                self.assertEqual(result["slotStates"]["credits"], {"state": "unknown", "reason": "prepaid-organization-unknown"})

    def test_stalled_required_read_fails_before_the_deadline(self) -> None:
        """129. Waiting the configured timeout past the deadline lets the runner kill the Reader instead of its own failure."""
        for transport, sent_before in BEFORE_USAGE.items():
            with self.subTest(transport=transport):
                status, out, err, timeouts, sent = self.replay(transport, str(USAGE_URL))
                self.assertEqual(status, 1, "the runner killed the Reader at its deadline")
                self.assertEqual((out, err), ("", "usage: claude usage request failed\n"))
                self.assertEqual(timeouts, [FULL_BUDGET] * (sent_before + 1))
                self.assertEqual(sent, sent_before + 1)


if __name__ == "__main__":
    unittest.main()
