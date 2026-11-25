# pyright: strict
"""Stop a real request at the deadline its runner sets, against a local server that trickles its reply."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Event, Thread
import time
import unittest

from pydantic import HttpUrl, SecretStr

from credential_usage.transport import DEADLINE_MARGIN, DirectHttp, HttpPolicy, HttpRequest, RequestFailure

BYTES = 300
BYTE_EVERY = 0.02
BUDGET = 1.0


class TrickleServer(ThreadingHTTPServer):
    """Answer one request, then send its body one byte at a time until the test ends."""

    daemon_threads = True

    def __init__(self) -> None:
        self.stop = Event()
        self.bytes_left = BYTES
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
        while self.server.bytes_left > 0 and not self.server.stop.wait(BYTE_EVERY):
            try:
                self.wfile.write(b"x")
                self.wfile.flush()
            except OSError:
                return
            self.server.bytes_left -= 1


class DeadlineTests(unittest.TestCase):
    def test_direct_http_stops_waiting_at_the_deadline(self) -> None:
        """127. A trickling reply never trips the socket timeout, so without the caller's wait the request runs to the reply's end."""
        with TrickleServer() as server:
            Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True).start()
            try:
                url = HttpUrl(f"http://127.0.0.1:{server.server_port}/usage")
                client = DirectHttp(url, SecretStr("local-only"), HttpPolicy(timeout=30), time.monotonic() + BUDGET + DEADLINE_MARGIN)
                started = time.monotonic()
                with self.assertRaises(RequestFailure):
                    client.request(HttpRequest(method="POST", url=url, body="query"))
                elapsed = time.monotonic() - started
            finally:
                server.stop.set()
                server.shutdown()
                server.server_close()
        # The reply needs six seconds, so only the caller's wait ends the request sooner.
        self.assertLess(elapsed, BUDGET * 2.5)
        self.assertLess(server.bytes_left, BYTES, "the reply never reached its trickling body")


if __name__ == "__main__":
    unittest.main()
