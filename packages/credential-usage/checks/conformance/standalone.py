# pyright: strict
"""Replay a fixture pair's direct cases through an installed Reader command whose HTTP is scripted offline.

Owner checks call `main` with a pair directory and a packaged offline command. The command's interpreter
carries a `.pth` hook that calls `install_direct_replay` at startup, after the check-only socket guard.
"""

from collections.abc import Sequence
from datetime import UTC, datetime, timedelta
import json
import os
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
from typing import Any
import unittest

import urllib3
from urllib3.response import HTTPResponse
from urllib3.util import Retry

# Isolated Python omits the script directory, which holds the shared suite.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from suite import Case, Document, Inputs, Pair, Reply, ScriptedNetwork, case_environment, compare, public_result

OBSERVED_AT = "[observedAt]"


def install_direct_replay(retries: int, timeout: float) -> None:
    """Install one fixture script after the check-only interpreter has guarded sockets."""
    root = Path(os.environ["USAGE_DIRECT_REPLAY"])
    network = ScriptedNetwork(datetime.now(UTC), [Reply(*reply) for reply in json.loads((root / "replay.json").read_text())])

    def request(method: str, url: str, **kwargs: Any) -> HTTPResponse:
        policy = kwargs.get("retries")
        if not isinstance(policy, Retry) or policy.total != retries or kwargs.get("timeout") != timeout:
            os._exit(98)
        try:
            return network.request(method, url, **kwargs)
        finally:
            with (root / "requests.jsonl").open("a") as trace:
                trace.write(json.dumps(network.requests[-1]) + "\n")

    setattr(urllib3, "request", request)


def stamped(document: Document | None, started: datetime, finished: datetime) -> Document | None:
    """Replace the observation instant with its marker once it is a UTC instant inside the run."""
    if document is None or "observedAt" not in document:
        return document
    value = document["observedAt"]
    try:
        instant = datetime.fromisoformat(value) if isinstance(value, str) and value.endswith("Z") else None
    except ValueError:
        instant = None
    if instant is None or instant.utcoffset() != timedelta(0) or not started <= instant <= finished:
        return None
    return document | {"observedAt": OBSERVED_AT}


class Installed(unittest.TestCase):
    """Run the packaged command with its case's script, then apply the shared assertions."""

    maxDiff = None
    inputs: Inputs
    case: Case
    command: str

    def test_replay(self) -> None:
        """Capture the installed command's streams and trace, then compare its whole public boundary with the pair."""
        inputs, case = self.inputs, self.case
        credentials = inputs.credentials | case.scenario.credentials
        replies = [inputs.replies[name] for name in case.scenario.replies]
        with TemporaryDirectory() as tmp:
            (Path(tmp) / "replay.json").write_text(json.dumps([[reply.status, reply.body] for reply in replies]))
            # A Reader that fails before its first request never creates the trace.
            (Path(tmp) / "requests.jsonl").touch()
            env = case_environment(Path(tmp), inputs, case.scenario) | {"USAGE_DIRECT_REPLAY": tmp}
            started = datetime.now(UTC)
            try:
                process = subprocess.run([self.command], env=env, capture_output=True, text=True, timeout=30, check=False)
                status, out, err = process.returncode, process.stdout, process.stderr
            except (OSError, subprocess.TimeoutExpired):
                # Exception text can include a command path.
                status, out, err = None, "", ""
            finished = datetime.now(UTC)
            trace = [json.loads(line) for line in (Path(tmp) / "requests.jsonl").read_text().splitlines()]
        # An installed Reader stamps the real time, which the pair cannot know: both sides carry the marker instead.
        result = case.expected.result
        expected = case.expected.model_copy(update={"result": result | {"observedAt": OBSERVED_AT} if "observedAt" in result else result})
        compare(self, credentials, case._replace(expected=expected), status, out, err, trace, stamped(public_result(status, out, err), started, finished))


def main(args: Sequence[str]) -> int:
    """Replay the pair's direct cases through the installed command and report each failed comparison."""
    if len(args) != 2:
        print("usage: standalone.py <pair directory> <offline direct command>", file=sys.stderr)
        return 2
    try:
        pair = Pair.read(Path(args[0]))
    except (OSError, ValueError) as error:
        print(f"invalid fixture: {error}", file=sys.stderr)
        return 2
    tests = unittest.TestSuite(
        unittest.defaultTestLoader.loadTestsFromTestCase(type(case.name, (Installed,), {"inputs": pair.inputs, "case": case, "command": args[1]}))
        for name, case in pair.cases.items() if name.endswith("/direct")
    )
    return int(not unittest.TextTestRunner(verbosity=2).run(tests).wasSuccessful())


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
