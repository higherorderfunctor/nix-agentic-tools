"""Check captures and retry timing at the runner's process boundary.

The Nix check imports the installed package. Local runs use its checkout path.
"""

from datetime import UTC, datetime, timedelta
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

PACKAGE = Path(__file__).resolve().parents[2] / "python"
if PACKAGE.is_dir():
    sys.path.insert(0, str(PACKAGE))

from credential_usage import runner


class TestRunner(unittest.TestCase):
    def test_shared_commands_retain_final_attempt_time_and_safe_outcome(self) -> None:
        start = datetime(2026, 1, 1, tzinfo=UTC)
        attempts = {"fails": iter((2, 1, 3)), "late": iter((7, 2, 0)), "sibling": iter((0,))}
        registrations = [
            runner.ReaderRegistration(name=name, command=command)
            for name, command in (
                ("late-success", "late"),
                ("shared-command", "late"),
                ("repeated-failure", "fails"),
                ("absent-command", None),
                ("healthy-sibling", "sibling"),
            )
        ]
        trace: list[tuple[str, float]] = []
        calls = 0

        def run(argv: list[str], *, timeout: float) -> subprocess.CompletedProcess[str]:
            """Advance the fake clock by one second per process, not per sleep."""
            nonlocal calls
            command = argv[-1].split("\n", 1)[1]
            status = next(attempts.get(command, iter(())), None)
            if status is None:
                self.fail(f"unexpected invocation of {command!r}")
            calls += 1
            trace.append((command, timeout))
            return subprocess.CompletedProcess(argv, status, f"{command} stdout {status}", "private stderr")

        policy = runner.ReaderPolicy(retries=2, retry_delay=0.75, timeout=3.5)
        with patch("time.sleep", side_effect=lambda delay: trace.append(("sleep", delay))):
            captures = runner.capture_readers(
                registrations,
                "bash",
                policy,
                run=run,
                clock=lambda: start + timedelta(seconds=calls),
            )

        expected = {
            # Exhaustion must not lose or mistime a later, unrelated command.
            "healthy-sibling": runner.ReaderSuccess(start.replace(second=7), "sibling stdout 0"),
            # A success after two retries must not use an earlier attempt's output or time.
            "late-success": runner.ReaderSuccess(start.replace(second=3), "late stdout 0"),
            # Exhaustion must report the final exit status without leaking process output.
            "repeated-failure": runner.ReaderFailure(start.replace(second=6), "Reader exited 3"),
        }
        for name, want in expected.items():
            with self.subTest(reader=name):
                self.assertIs(type(captures[name]), type(want))
                self.assertEqual(vars(captures[name]), vars(want))

        # Neither an alias nor a registration without a command should start a process.
        # Catch extra attempts, a budget shared across commands, a sleep outside
        # the retry gap, or a timeout applied only to the initial attempt.
        self.assertEqual(trace, [
            ("late", 3.5), ("sleep", 0.75), ("late", 3.5), ("sleep", 0.75), ("late", 3.5),
            ("fails", 3.5), ("sleep", 0.75), ("fails", 3.5), ("sleep", 0.75), ("fails", 3.5),
            ("sibling", 3.5),
        ])


if __name__ == "__main__":
    unittest.main()
