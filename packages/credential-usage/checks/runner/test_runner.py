"""Compare the runner's captures and process trace to the offline check's fixture.

The Nix check imports the installed package. Local runs use its checkout path.
"""

from datetime import UTC, datetime, timedelta
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

from pydantic import BaseModel, TypeAdapter

CASES = Path(__file__).parent / "cases" / "process"
PACKAGE = Path(__file__).resolve().parents[2] / "python"
if PACKAGE.is_dir():
    sys.path.insert(0, str(PACKAGE))

from credential_usage import runner


class ProcessFixture(BaseModel):
    """Supply the manifest registrations and scripted outcomes for the fake process."""

    attempts: dict[str, list[int]]
    policy: runner.ReaderPolicy
    readers: list[runner.ReaderRegistration]


class TestRunner(unittest.TestCase):
    """Exercise retries and attribution together so aliases share the final observation."""

    def test_shared_commands_retain_final_attempt_time_and_safe_outcome(self) -> None:
        """Catch extra calls, stale timestamps and failure details leaking to callers."""
        fixture = ProcessFixture.model_validate_json(
            (CASES / "input.json").read_bytes()
        )
        expected = json.loads((CASES / "expected.json").read_text())["snapshot"]
        calls: list[str] = []
        delays: list[float] = []
        timeouts: list[float] = []

        def run(argv: list[str], *, timeout: float) -> subprocess.CompletedProcess[str]:
            """Advance the fake clock by one second for each attempted read."""
            command = argv[-1].split("\n", 1)[1]
            calls.append(command)
            timeouts.append(timeout)
            status = fixture.attempts[command].pop(0)
            return subprocess.CompletedProcess(
                argv, status, f"{command} stdout", "private stderr"
            )

        def clock() -> datetime:
            """Expose elapsed attempts independently of any routing evaluation time."""
            return datetime(2026, 1, 1, tzinfo=UTC) + timedelta(seconds=len(calls))

        with patch("time.sleep", side_effect=delays.append):
            captures = runner.capture_readers(
                fixture.readers, "bash", fixture.policy, run=run, clock=clock
            )
        self.assertIs(captures["absent-command"], runner.MissingReader.NO_COMMAND)
        actual = TypeAdapter(dict[str, runner.ReaderCapture]).dump_python(
            captures, mode="json"
        )
        expected_captures = expected.pop("captures")
        for name in sorted(captures.keys() | expected_captures.keys()):
            with self.subTest(behavior=name):
                self.assertIn(name, expected_captures)
                self.assertIn(name, captures)
                self.assertEqual(actual[name], expected_captures[name])
        with self.subTest(behavior="process trace"):
            self.assertEqual(
                {"calls": calls, "delays": delays, "timeouts": timeouts}, expected
            )

    def test_each_attempt_carries_its_deadline_to_the_reader(self) -> None:
        """126. A Reader that inherits a stale or no deadline cannot bound its optional reads."""
        reader = [sys.executable, "-c", "import os; print(os.environ.get('CREDENTIAL_USAGE_READER_TIMEOUT', ''), end='')"]
        with patch.dict(os.environ, {"CREDENTIAL_USAGE_READER_TIMEOUT": "999"}):
            process = runner.run_reader(reader, timeout=3.5)
        self.assertEqual((process.returncode, process.stdout), (0, "3.5"))


if __name__ == "__main__":
    unittest.main()
