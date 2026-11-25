"""Compare offline CPA request traces and direct HTTP calls to their expected wire contracts."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import sys
from threading import Event, Thread
import time
import unittest
from typing import NamedTuple
from unittest.mock import ANY, patch

from pydantic import BaseModel, HttpUrl, JsonValue, SecretStr
from urllib3.response import HTTPResponse

HERE = Path(__file__).resolve().parent
CASES = HERE / "cases" / "binding"
sys.path.insert(0, str(HERE))
packages = HERE.parents[1].parent
# A checkout run imports both owners' sources; the Nix check imports the installed modules.
# `cliproxyapi` is a namespace package, so its root is the repository's packages directory.
if (packages / "credential-usage" / "python").is_dir():
    sys.path[:0] = [str(packages / "credential-usage" / "python"), str(packages)]

from mock import RecordingTransport
from cliproxyapi.usage.transport import CpaInstance, UnknownBinding
from credential_usage.transport import DEADLINE_MARGIN, DirectHttp, HttpPolicy, HttpRequest, RequestFailure


class Case(NamedTuple):
    """Choose a credential and replay the ordered management replies for this case."""

    provider: str | None
    discover_keys: bool
    pin: str | None
    replies: list[str]
    request: str = "usage"


class Fixture(BaseModel):
    """The shared fixture supplies an instance, vendor request and named CPA responses."""

    instance: HttpUrl
    direct: dict[str, str]
    discovery_base: HttpUrl
    requests: dict[str, HttpRequest]
    surfaces: tuple[str, ...]
    replies: dict[str, tuple[int, JsonValue]]
    cases: dict[str, Case]


fixture = Fixture.model_validate_json((CASES / "input.json").read_bytes())
expected = json.loads((CASES / "expected.json").read_bytes())


class TrickleServer(ThreadingHTTPServer):
    """Answer one request, then send its body one byte at a time until the test ends."""

    daemon_threads = True
    stop = Event()
    bytes_left = 200

    def __init__(self) -> None:
        super().__init__(("127.0.0.1", 0), TrickleHandler)


class TrickleHandler(BaseHTTPRequestHandler):
    """Keep each socket read short so the client's socket timeout never fires."""

    def log_message(self, format: str, *args: object) -> None:
        """Keep the fixture server's access log out of the check's output."""

    def do_POST(self) -> None:
        if not isinstance(self.server, TrickleServer):
            raise TypeError("TrickleHandler serves a TrickleServer only")
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.send_response(200)
        self.send_header("Content-Length", str(self.server.bytes_left))
        self.end_headers()
        while self.server.bytes_left > 0 and not self.server.stop.wait(0.05):
            try:
                self.wfile.write(b"x")
                self.wfile.flush()
            except OSError:
                return
            self.server.bytes_left -= 1


class TransportTests(unittest.TestCase):
    def test_cpa_binds_one_credential(self) -> None:
        """Compare each complete request and outcome, including refused and failed calls."""
        requests = {
            key: expected["request_defaults"] | value
            for key, value in expected["requests"].items()
        }
        self.assertEqual(set(fixture.cases), set(expected["cases"]))
        for name, case in fixture.cases.items():
            with self.subTest(behavior=name):
                mock = RecordingTransport(fixture.replies[key] for key in case.replies)
                instance = CpaInstance(fixture.instance, mock)
                try:
                    binding = instance.bind(
                        discovery_base=fixture.discovery_base,
                        provider=case.provider,
                        surfaces=fixture.surfaces if case.discover_keys else None,
                        pin=case.pin,
                    )
                    outcome = (
                        binding.value
                        if isinstance(binding, UnknownBinding)
                        else (binding.account_name, binding.request(fixture.requests[case.request]).model_dump())
                    )
                except RequestFailure as error:
                    outcome = str(error)
                calls, result = expected["cases"][name]
                self.assertEqual(mock.requests, [requests[key] for key in calls])
                self.assertEqual(
                    outcome, (None, expected["success"]) if result == "success" else result
                )

    def test_direct_http_binds_the_token_and_owns_network_retries(self) -> None:
        """Check the direct authorization, network policy and refusal to cross origins."""
        request = fixture.requests["usage"]
        policy = HttpPolicy(timeout=3, retries=2)
        client = DirectHttp(request.url, SecretStr("local-only"), policy)
        reply = HTTPResponse(status=201, body=b"usage")
        with patch("urllib3.request", return_value=reply) as send:
            result = client.request(request)
            self.assertEqual(result.model_dump(), {"status_code": 201, "body": "usage"})
            with self.assertRaisesRegex(RequestFailure, "origin mismatch"):
                client.request(fixture.requests["elsewhere"])
            send.assert_called_once_with(
                "POST",
                "https://vendor.test/usage",
                headers={"Accept": "text/plain", "Authorization": "Bearer local-only"},
                body="query",
                timeout=3,
                redirect=False,
                retries=ANY,
            )
            self.assertEqual(send.call_args.kwargs["retries"].total, 2)
            send.return_value = HTTPResponse(status=503, body=b"local-only")
            with self.assertRaisesRegex(RequestFailure, "^HTTP 503$"):
                client.request(request)
            name = "private network exception"
            send.side_effect = OSError(fixture.direct[name])
            with self.assertRaises(RequestFailure) as failure:
                client.request(request)
            self.assertEqual(str(failure.exception), expected["direct"][name])

    def test_direct_http_stops_waiting_at_the_deadline(self) -> None:
        """127. A trickling reply never trips the socket timeout, so removing the caller's wait lets it run to the end."""
        TrickleServer.stop.clear()
        TrickleServer.bytes_left = 200
        with TrickleServer() as server:
            Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True).start()
            try:
                url = HttpUrl(f"http://127.0.0.1:{server.server_port}/usage")
                deadline = 0.5 + DEADLINE_MARGIN
                client = DirectHttp(url, SecretStr("local-only"), HttpPolicy(timeout=30), time.monotonic() + deadline)
                started = time.monotonic()
                with self.assertRaisesRegex(RequestFailure, "^HTTP request deadline passed$"):
                    client.request(HttpRequest(method="POST", url=url, body="query"))
                # The reply needs ten seconds; anything well past the half-second wait is the library keeping time.
                self.assertLess(time.monotonic() - started, 3)
            finally:
                TrickleServer.stop.set()
                server.shutdown()
                server.server_close()


if __name__ == "__main__":
    unittest.main()
