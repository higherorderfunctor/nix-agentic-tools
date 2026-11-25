# pyright: strict
"""Replay a fixture pair through an installed Reader command.

Owner checks call `main` with a pair directory and a packaged command. Each CPA
case gets a local HTTP server that answers the scenario's requests. Direct
cases that stop before sending a request exercise the installed command's
preflight. The same pair checks all direct requests in the imported suite.
"""

from collections.abc import Sequence
from datetime import UTC, datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from importlib.metadata import version
import json
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

from suite import Case, Document, IncompletePair, Inputs, Pair, Reply, Request, ScriptedNetwork, case_environment, private_strings, public_result, same_json

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


def installed_differences(inputs: Inputs, case: Case, command: str) -> list[str]:
    """Run the installed command once and return a safe label for each failed comparison."""
    errors: list[str] = []
    replies = [inputs.replies[name] for name in case.scenario.replies]
    credentials = inputs.credentials | case.scenario.credentials
    masks = {
        spelling: f"[credential:{name}]"
        for name, content in credentials.items()
        for value in private_strings(content)
        for spelling in (value, json.dumps(value)[1:-1])
    }
    network = ScriptedNetwork(inputs.now, replies, masks)
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
            text = network.mask(raw.decode(errors="replace"))
            try:
                payload = TypeAdapter(JsonValue).validate_json(text)
            except ValidationError:
                payload = text
        return Request(
            method=network.mask(method), url=network.mask(fixture + target),
            headers={network.mask(k): network.mask(v) for k, v in reader_headers(headers).items()}, body=payload,
        )

    private = [*masks, *(value for reply in replies if reply.private or not 200 <= reply.status < 300
                         for value in private_strings(reply.body))]
    if any(secret in stream or json.dumps(secret)[1:-1] in stream for stream in (out, err) for secret in private):
        errors.append("leak")
    if len(server.received) != len(replies):
        errors.append("extra request" if len(server.received) > len(replies) else "missing request")
    if not same_json(
        [request.model_dump() for request in map(wire, server.received)],
        [request.model_dump() for request in case.expected.requests],
    ):
        errors.append("trace")
    expected = dict(case.expected.result)
    if "observedAt" in expected:
        expected["observedAt"] = OBSERVED_AT
    observed = stamped(public_result(status, out.replace(server.origin, fixture), err), started, finished)
    if not same_json(observed, expected):
        errors.append("result")
    return [f"{case.name}: {error}" for error in errors]


def main(args: Sequence[str]) -> int:
    """Replay the pair's cases that can run without contacting a vendor."""
    if len(args) != 2:
        print("usage: standalone.py <pair directory> <Reader command>", file=sys.stderr)
        return 1
    try:
        pair = Pair.read(Path(args[0]))
    except IncompletePair as error:
        print(error, file=sys.stderr)
        return 1
    cases = [case for name, case in pair.cases.items() if name.endswith("/cpa") or not case.expected.requests]
    if not cases:
        print("pair: no cases can run through the installed command", file=sys.stderr)
        return 1
    errors = [error for case in cases for error in installed_differences(pair.inputs, case, args[1])]
    for error in errors:
        print(error, file=sys.stderr)
    return int(bool(errors))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
