"""Run registered Readers for the routing helper and return their raw captures.

Registrations with the same command share its final outcome and completion time.
The caller interprets successful stdout and decides how each pool ranks.
"""

from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime
from enum import Enum
import os
import signal
import subprocess
import time
from typing import Annotated, Protocol

from pydantic import BaseModel, ConfigDict, Field, TypeAdapter

from credential_usage.transport import DEADLINE_VARIABLE


class ReaderRegistration(BaseModel):
    """The runner uses the manifest name to attribute the command's result."""

    model_config = ConfigDict(strict=True)
    command: str | None
    name: Annotated[str, Field(pattern=r"\S")]


reader_registrations = TypeAdapter(
    list[ReaderRegistration], config=ConfigDict(strict=True)
)


class ReaderPolicy(BaseModel):
    """The runner applies these limits to each distinct command."""

    model_config = ConfigDict(frozen=True, strict=True, allow_inf_nan=False)
    retries: int = Field(default=1, ge=0)
    retry_delay: float = Field(default=2, ge=0)
    timeout: float = Field(default=10, gt=0)


@dataclass(frozen=True, eq=False)
class ReaderSuccess:
    """The parser receives stdout and the time this invocation finished."""

    completed_at: datetime
    stdout: str


@dataclass(frozen=True, eq=False)
class ReaderFailure:
    """A caller can report a failed invocation without exposing its output."""

    completed_at: datetime
    reason: str


class MissingReader(Enum):
    """The helper keeps pools without a registered command available as unmeasured."""

    NO_COMMAND = "no registered Reader"


ReaderCapture = ReaderSuccess | ReaderFailure | MissingReader


class ReaderProcess(Protocol):
    """The runner needs one shell invocation with a per-attempt timeout."""

    def __call__(
        self, argv: list[str], *, timeout: float
    ) -> subprocess.CompletedProcess[str]: ...


def run_reader(argv: list[str], *, timeout: float) -> subprocess.CompletedProcess[str]:
    """Run the runner's argv and reap the whole process group on timeout."""
    with subprocess.Popen(
        argv,
        env={**os.environ, DEADLINE_VARIABLE: str(timeout)},
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    ) as process:
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
            raise
        return subprocess.CompletedProcess(argv, process.returncode, stdout, stderr)


def capture_command(
    command: str,
    shell: str,
    policy: ReaderPolicy,
    run: ReaderProcess,
    clock: Callable[[], datetime],
) -> ReaderSuccess | ReaderFailure:
    """Collect the final outcome of one command, retrying a lost or failed process."""
    argv = [
        shell,
        "-euETo",
        "pipefail",
        "-c",
        "shopt -s inherit_errexit 2>/dev/null || :\n" + command,
    ]
    retries_left = policy.retries
    while True:
        try:
            process = run(argv, timeout=policy.timeout)
        except subprocess.TimeoutExpired:
            reason = "Reader timed out"
        except OSError:
            reason = "Reader could not execute"
            break
        except UnicodeDecodeError:
            reason = "invalid Reader output"
            break
        except ValueError:
            # Popen rejects a NUL byte in argv before the Reader starts.
            reason = "invalid Reader command"
            break
        else:
            if process.returncode == 0:
                return ReaderSuccess(clock().astimezone(UTC), process.stdout)
            reason = f"Reader exited {process.returncode}"
        if retries_left == 0:
            break
        retries_left -= 1
        time.sleep(policy.retry_delay)
    return ReaderFailure(clock().astimezone(UTC), reason)


def capture_readers(
    registrations: list[ReaderRegistration],
    shell: str,
    policy: ReaderPolicy = ReaderPolicy(),
    *,
    run: ReaderProcess = run_reader,
    clock: Callable[[], datetime] = lambda: datetime.now(UTC),
) -> dict[str, ReaderCapture]:
    """Attribute one capture per command to every registration that shares it."""
    commands: dict[str, ReaderSuccess | ReaderFailure] = {}
    captures: dict[str, ReaderCapture] = {}
    for registration in registrations:
        command = registration.command
        if command is None:
            captures[registration.name] = MissingReader.NO_COMMAND
        else:
            if command not in commands:
                commands[command] = capture_command(command, shell, policy, run, clock)
            captures[registration.name] = commands[command]
    return captures
