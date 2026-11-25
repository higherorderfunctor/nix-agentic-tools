# pyright: strict
"""Replay a fixture pair through an installed Reader command.

Owner checks call `main` with a pair directory and a packaged command. Each CPA
case gets a local HTTP server that answers the scenario's requests. An owner
can also provide a build of the command that forbids sockets to check direct
preflight cases. The same pair checks all direct requests in the imported suite.
A failed comparison prints the case, then the whole expected and observed objects with private content replaced.
"""

from collections.abc import Sequence
from datetime import UTC, datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from importlib.metadata import version
from pathlib import Path
import re
import subprocess
import sys
from tempfile import TemporaryDirectory
from threading import Thread
from typing import Any

from pydantic import JsonValue, TypeAdapter, ValidationError

# Isolated Python omits the script directory, which holds the shared suite.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from suite import (
    Case, Difference, Document, IncompletePair, Inputs, Pair, PublicOutput, Reply, Request, ScriptedNetwork, case_environment, diff_of,
    public_result, redaction, result_difference, same_json,
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


def installed_differences(inputs: Inputs, case: Case, command: str) -> list[Difference]:
    """Run the installed command once and return a safe report for each failed comparison."""
    errors: list[Difference] = []
    replies = [inputs.replies[name] for name in case.scenario.replies]
    credentials = inputs.credentials | case.scenario.credentials
    redactor = redaction(credentials, replies)
    network = ScriptedNetwork(inputs.now, replies, redactor.credential_text)
    server = ReplayServer(replies)
    thread = Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
    thread.start()
    try:
        with TemporaryDirectory() as tmp:
            env = case_environment(Path(tmp), inputs.executables, case.scenario.env, credentials)
            origins = {value for value in env.values() if ORIGIN.fullmatch(value)}
            if len(origins) > 1:
                raise IncompletePair(f"{case.name}: more than one origin to repoint")
            pointed = {key: server.origin if ORIGIN.fullmatch(value) else value for key, value in env.items()}
            started = datetime.now(UTC)
            try:
                process = subprocess.run([command], env=pointed, capture_output=True, text=True, timeout=30, check=False)
            except (OSError, subprocess.TimeoutExpired):
                # Exception text can include a command path; the case reports only a failed result.
                status, out, err = None, "", ""
            else:
                status, out, err = process.returncode, process.stdout, process.stderr
            finished = datetime.now(UTC)
    finally:
        server.shutdown()
        server.server_close()
    fixture = next(iter(origins), "")

    def wire(request: WireRequest) -> Request:
        """Mask credentials in one recorded request, read a present body as JSON and restore the fixture's origin."""
        method, target, headers, raw = request
        payload: JsonValue = None
        if raw:
            text = network.credential_text(raw.decode(errors="replace"))
            try:
                payload = TypeAdapter(JsonValue).validate_json(text)
            except ValidationError:
                payload = text
        return Request(
            method=network.credential_text(method), url=network.credential_text(fixture + target),
            headers={network.credential_text(k): network.credential_text(v) for k, v in reader_headers(headers).items()}, body=payload,
        )

    if any(secret in stream for stream in (out, err) for secret in redactor.spellings):
        errors.append(Difference(f"{case.name}: leak"))
    if len(server.received) != len(replies):
        errors.append(Difference(f"{case.name}: extra request" if len(server.received) > len(replies) else f"{case.name}: missing request"))
    expected_trace: JsonValue = [request.model_dump() for request in case.expected.requests]
    trace: JsonValue = [request.model_dump() for request in map(wire, server.received)]
    if not same_json(trace, expected_trace):
        errors.append(Difference(f"{case.name}: trace", diff_of(expected_trace, trace, redactor)))
    expected = dict(case.expected.result)
    if "observedAt" in expected:
        expected["observedAt"] = OBSERVED_AT
    output = public_result(status, out.replace(server.origin, fixture), err)
    result = result_difference(case.name, expected, PublicOutput(stamped(output.accepted, started, finished), output.printed), redactor)
    if result is not None:
        errors.append(result)
    return errors


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
            if name.endswith("/direct") and not case.expected.requests
        ]
        if not direct:
            print("pair: no direct preflight cases for the offline command", file=sys.stderr)
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
