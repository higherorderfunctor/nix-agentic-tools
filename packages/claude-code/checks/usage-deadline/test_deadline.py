"""Replay vendor requests through the Claude Reader under the deadline its runner sets.

The Nix check passes the conformance suite and the fixture pair and imports the
installed modules. Each answered request takes one second of the fake clock; the
test names one request that stalls for as long as it was allowed to wait.
"""

# pyright: strict
# cspell:ignore connectionpool
from collections.abc import Mapping
from datetime import UTC, datetime
import json
import os
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from typing import NamedTuple
import unittest
from unittest.mock import patch
from pydantic import JsonValue
from urllib3.connectionpool import HTTPConnectionPool
from urllib3.exceptions import ReadTimeoutError
from urllib3.response import HTTPResponse

from claude_code.usage import cli
from claude_code.usage.claude import PROFILE_URL, USAGE_URL
from credential_usage.transport import DEADLINE_VARIABLE

CHECKOUT = Path(__file__).resolve().parents[3]
PAIR = Path(os.environ.get("USAGE_PAIR") or CHECKOUT / "claude-code" / "usage" / "cases")
SUITE = Path(os.environ.get("USAGE_SUITE") or CHECKOUT / "credential-usage" / "checks" / "conformance")
sys.path.insert(0, str(SUITE))

from suite import Case, Pair, Replay, ScriptedNetwork, captured_stream, case_environment

DEADLINE = 5
PROFILE_STALL = str(PROFILE_URL)
PREPAID_STALL = "https://api.anthropic.com/api/oauth/organizations/org-123/prepaid/credits"
TIMEOUT = "timeout"


class Stall(NamedTuple):
    """Name the request that never answers, or None when every request answers."""

    url: str | None


class Outcome(NamedTuple):
    """Keep the Reader's public result and what the fake clock and network saw."""

    status: int | None
    out: str
    err: str
    timeouts: list[float]
    sent: int


def credits_state(envelope: Mapping[str, JsonValue]) -> JsonValue | None:
    """Return the credits slot state of a printed envelope."""
    states = envelope["slotStates"]
    return states["credits"] if isinstance(states, dict) else None


class DeadlineTests(unittest.TestCase):
    """A stalled request costs the timeout it was given; the clock then shows whether the Reader survived."""

    def replay(self, transport: str, deadline: float, stall: Stall, policy: Mapping[str, object] | None = None) -> Outcome:
        """Run the Reader as the suite does, then discard its output once the runner would have killed it."""
        pair = Pair.read(PAIR)
        case: Case = pair.cases[f"grant-optional-terms/{transport}"]
        replay = Replay.for_case(pair.inputs, case)
        now = [0.0]
        timeouts: list[float] = []
        network = ScriptedNetwork(pair.inputs.now, replay.replies, replay.masks)
        answer = network.request

        def answering_or_stalling(
            method: str, url: str, *, headers: dict[str, str] | None = None, body: str | None = None,
            timeout: float = 0, **_: object,
        ) -> HTTPResponse:
            """Record the request, then stall instead of answering the request the test selected."""
            response = answer(method, url, headers=headers, body=body)
            timeouts.append(timeout)
            forwarded = json.loads(body)["url"] if body is not None else url
            if forwarded == stall.url:
                now[0] += timeout
                raise ReadTimeoutError(HTTPConnectionPool("stalled.invalid"), url, "stalled reply")
            now[0] += 1
            return response

        settings = case.scenario.env | {DEADLINE_VARIABLE: str(deadline)}
        if policy is not None:
            if transport == "direct":
                settings["CLAUDE_USAGE_DIRECT_POLICY"] = json.dumps(policy)
            else:
                settings["CLAUDE_USAGE_CPA_BINDING"] = json.dumps({
                    "endpoint": "https://proxy.example",
                    "managementKeyFile": "${credentials:management}",
                    "policy": policy,
                })
        with TemporaryDirectory() as tmp:
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
        if now[0] > deadline:
            return Outcome(None, "", "", timeouts, len(network.requests))
        return Outcome(status, out, err, timeouts, len(network.requests))

    def observed_windows(self, transport: str) -> JsonValue | None:
        """Return the windows the pair records for the case the Reader ran."""
        case: Case = Pair.read(PAIR).cases[f"grant-optional-terms/{transport}"]
        return case.expected.result["windows"]

    def assert_printed(self, outcome: Outcome) -> Mapping[str, JsonValue]:
        """Require a successful, silent Reader and return its public envelope."""
        status, out, err = outcome.status, outcome.out, outcome.err
        self.assertEqual(status, 0, "the runner killed the Reader at its deadline")
        self.assertTrue(err == "", "the Reader wrote to stderr")
        result: dict[str, JsonValue] = json.loads(out)
        return result

    def test_each_request_waits_only_for_what_is_left(self) -> None:
        """127. Reusing the first budget, dividing it by the retries, or sending a request with no time left passes no row."""
        for name, deadline, policy, transport, waits, credits in (
            ("the policy timeout is the smaller", 5, {"retries": 1, TIMEOUT: 2}, "direct", [2.0, 2.0, 2.0], "observed"),
            ("the policy timeout is the smaller", 5, {"retries": 1, TIMEOUT: 2}, "cpa", [2.0, 2.0, 2.0, 1.5], "observed"),
            ("the time left is the smaller", 5, None, "direct", [4.5, 3.5, 2.5], "observed"),
            ("the time left is the smaller", 5, None, "cpa", [4.5, 3.5, 2.5, 1.5], "observed"),
            ("an exhausted deadline sends nothing", 1.5, None, "direct", [1.0], "prepaid-organization-unknown"),
        ):
            with self.subTest(name, transport=transport):
                outcome = self.replay(transport, deadline, Stall(None), policy)
                result = self.assert_printed(outcome)
                self.assertEqual((outcome.timeouts, outcome.sent), (waits, len(waits)))
                self.assertEqual(credits_state(result), {"state": "unknown", "reason": credits} if credits != "observed" else {"state": "observed"})
        with self.subTest("an exhausted deadline sends nothing", transport="cpa"):
            outcome = self.replay("cpa", 1.5, Stall(None))
            self.assert_failed(outcome, "usage: claude usage request failed\n")
            self.assertEqual((outcome.timeouts, outcome.sent), ([1.0], 1))

    def test_stalled_optional_read_leaves_credits_unknown_and_keeps_windows(self) -> None:
        """128. A profile or prepaid request that outlasts the deadline lets the runner kill the Reader before it prints."""
        for name, url, transport, waits, credits in (
            ("profile", PROFILE_STALL, "direct", [4.5, 3.5], "prepaid-organization-unknown"),
            ("profile", PROFILE_STALL, "cpa", [4.5, 3.5, 2.5], "prepaid-organization-unknown"),
            ("prepaid", PREPAID_STALL, "direct", [4.5, 3.5, 2.5], "prepaid-unavailable"),
            ("prepaid", PREPAID_STALL, "cpa", [4.5, 3.5, 2.5, 1.5], "prepaid-unavailable"),
        ):
            with self.subTest(name, transport=transport):
                outcome = self.replay(transport, DEADLINE, Stall(url))
                result = self.assert_printed(outcome)
                self.assertEqual((outcome.timeouts, outcome.sent), (waits, len(waits)))
                self.assertEqual(result["windows"], self.observed_windows(transport))
                self.assertEqual(result["balances"], [])
                self.assertEqual(credits_state(result), {"state": "unknown", "reason": credits})

    def test_stalled_required_read_fails_before_the_deadline(self) -> None:
        """129. Waiting the configured timeout past the deadline lets the runner kill the Reader instead of its own failure."""
        for transport, waits in (("direct", [4.5]), ("cpa", [4.5, 3.5])):
            with self.subTest(transport=transport):
                outcome = self.replay(transport, DEADLINE, Stall(str(USAGE_URL)))
                self.assert_failed(outcome, "usage: claude usage request failed\n")
                self.assertEqual((outcome.timeouts, outcome.sent), (waits, len(waits)))

    def assert_failed(self, outcome: Outcome, line: str) -> None:
        """Require a Reader that failed before the deadline with exactly one public failure line."""
        self.assertEqual(outcome.status, 1, "the runner killed the Reader at its deadline")
        self.assertTrue(outcome.out == "", "the Reader printed an envelope before failing")
        self.assertTrue(outcome.err == line, "the failure line differs")


if __name__ == "__main__":
    unittest.main()
