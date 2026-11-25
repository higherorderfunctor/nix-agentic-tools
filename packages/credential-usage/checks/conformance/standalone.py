# pyright: strict
"""Replay a fixture pair through an installed Reader command.

Owner checks call `main` with a pair directory and a packaged command. Each CPA
case gets a local HTTP server. The direct command installs an offline HTTP
replay at startup and refuses sockets while preserving the vendor origin.
A failed comparison prints the case, then the whole expected and observed objects.
"""

from collections.abc import Sequence
from datetime import UTC, datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from importlib.metadata import version
from pathlib import Path
import json
import os
import re
import subprocess
import sys
from tempfile import TemporaryDirectory
from threading import Thread
from typing import Any

import urllib3
from urllib3.response import HTTPResponse
from urllib3.util import Retry

# Isolated Python omits the script directory, which holds the shared suite.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from suite import (
    Case, Difference, Document, IncompletePair, Inputs, Pair, Replay, Reply, Request, ScriptedNetwork,
    case_environment, conceal, public_result, recorded_request,
)

WireRequest = tuple[str, str, dict[str, str], bytes]
ORIGIN = re.compile(r"https?://[^/]+")
OBSERVED_AT = "[observedAt]"


class ReplayServer(ThreadingHTTPServer):
    """Answer each request with the next scripted reply and count the requests that outlast them."""

    def __init__(self, replies: Sequence[Reply]) -> None:
        super().__init__(("127.0.0.1", 0), ReplayHandler)
        self.replies = list(replies)
        self.received: list[WireRequest] = []

    @property
    def origin(self) -> str:
        """Return the origin a case's proxy URL is repointed to."""
        return f"http://127.0.0.1:{self.server_port}"


class ReplayHandler(BaseHTTPRequestHandler):
    """Record a request before replying, so a Reader that sends an extra request still fails its case."""

    def do_GET(self) -> None:
        self.replay()

    def do_POST(self) -> None:
        self.replay()

    def log_message(self, format: str, *args: Any) -> None:
        """Keep the fixture server's access log out of the check's output."""

    def replay(self) -> None:
        if not isinstance(self.server, ReplayServer):
            raise TypeError("ReplayHandler serves a ReplayServer only")
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        headers = {str(name): str(value) for name, value in self.headers.items()}
        self.server.received.append((self.command, self.path, headers, body))
        reply = self.server.replies.pop(0) if self.server.replies else None
        # A request without a scripted reply still needs an answer to end the Reader.
        self.send_response(reply.status if reply else 500)
        self.end_headers()
        self.wfile.write(reply.body.encode() if reply else b"")


def reader_headers(headers: dict[str, str]) -> dict[str, str]:
    """Keep the headers the Reader sent; a real socket adds framing and urllib3's own defaults."""
    library_defaults = {"Accept-Encoding": "identity", "User-Agent": f"python-urllib3/{version('urllib3')}"}
    return {
        name: value for name, value in headers.items()
        if name not in {"Content-Length", "Host"} and library_defaults.get(name) != value
    }


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


def install_direct_replay(retries: int, timeout: float) -> None:
    """Install one fixture script after the check-only interpreter has guarded sockets."""
    root = Path(os.environ["USAGE_DIRECT_REPLAY"])
    replies, masks = json.loads((root / "replay.json").read_text())
    network = ScriptedNetwork(datetime.now(UTC), [Reply(*reply) for reply in replies], masks)

    def request(method: str, url: str, **kwargs: Any) -> HTTPResponse:
        policy = kwargs.get("retries")
        if not isinstance(policy, Retry) or policy.total != retries or kwargs.get("timeout") != timeout:
            os._exit(98)
        try:
            return network.request(method, url, **kwargs)
        finally:
            with (root / "requests.jsonl").open("a") as trace:
                trace.write(network.requests[-1].model_dump_json() + "\n")

    setattr(urllib3, "request", request)


def run_installed(command: str, env: dict[str, str]) -> tuple[int | None, str, str, datetime, datetime]:
    """Capture stdout, stderr and the completed process interval."""
    started = datetime.now(UTC)
    try:
        process = subprocess.run([command], env=env, capture_output=True, text=True, timeout=30, check=False)
    except (OSError, subprocess.TimeoutExpired):
        # Exception text can include a command path.
        return None, "", "", started, datetime.now(UTC)
    return process.returncode, process.stdout, process.stderr, started, datetime.now(UTC)


def replay_cpa(
    case: Case, replay: Replay, command: str, env: dict[str, str],
) -> tuple[tuple[int | None, str, str, datetime, datetime], list[Request], str, str]:
    """Capture the installed CPA command's real loopback HTTP requests."""
    origins = {value for value in env.values() if ORIGIN.fullmatch(value)}
    if len(origins) > 1:
        raise IncompletePair(f"{case.name}: more than one origin to repoint")
    fixture = next(iter(origins), "")
    server = ReplayServer(replay.replies)
    thread = Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
    thread.start()
    try:
        pointed = {key: server.origin if ORIGIN.fullmatch(value) else value for key, value in env.items()}
        output = run_installed(command, pointed)
    finally:
        server.shutdown()
        server.server_close()
    mask = conceal(replay.masks)

    requests = [
        recorded_request(mask, method, fixture + target, reader_headers(headers), raw.decode(errors="replace") if raw else None)
        for method, target, headers, raw in server.received
    ]
    return output, requests, server.origin, fixture


def installed_differences(inputs: Inputs, case: Case, command: str) -> list[Difference]:
    """Run the packaged command with the replay for this transport and compare its public behavior."""
    replay = Replay.for_case(inputs, case)
    with TemporaryDirectory() as tmp:
        root = Path(tmp)
        env = case_environment(root, inputs.executables, case.scenario.env, replay.credentials)
        if case.name.endswith("/direct"):
            (root / "replay.json").write_text(json.dumps([replay.replies, replay.masks]))
            trace = root / "requests.jsonl"
            trace.touch()
            output = run_installed(command, env | {"USAGE_DIRECT_REPLAY": tmp})
            requests = [Request.model_validate_json(line) for line in trace.read_text().splitlines()]
            origin = fixture = ""
        else:
            output, requests, origin, fixture = replay_cpa(case, replay, command, env)
    status, out, err, started, finished = output
    expected = dict(case.expected.result)
    if "observedAt" in expected:
        expected["observedAt"] = OBSERVED_AT
    observed = stamped(public_result(status, out.replace(origin, fixture) if origin else out, err), started, finished)
    return replay.compare(case, out, err, requests, expected, observed)


def main(args: Sequence[str]) -> int:
    """Replay the pair's cases that can run without contacting a vendor."""
    if len(args) not in (2, 3):
        print("usage: standalone.py <pair directory> <CPA command> [<offline direct command>]", file=sys.stderr)
        return 1
    try:
        pair = Pair.read(Path(args[0]))
    except IncompletePair as error:
        print(error, file=sys.stderr)
        return 1
    runs = [(case, args[1]) for name, case in pair.cases.items() if name.endswith("/cpa")]
    if len(args) == 3:
        direct = [
            (case, args[2]) for name, case in pair.cases.items()
            if name.endswith("/direct")
        ]
        if not direct:
            print("pair: no direct cases for the offline command", file=sys.stderr)
            return 1
        runs.extend(direct)
    if not runs:
        print("pair: no cases can run through the installed command", file=sys.stderr)
        return 1
    errors = [error for case, command in runs for error in installed_differences(pair.inputs, case, command)]
    for error in errors:
        print(error, file=sys.stderr)
    return int(bool(errors))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
