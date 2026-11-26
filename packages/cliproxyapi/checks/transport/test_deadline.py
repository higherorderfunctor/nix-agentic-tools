# pyright: strict
"""Stop a real request at the deadline its runner sets, against a local server that trickles its reply."""
from socket import socket
from threading import Event, Thread
import time
import unittest

from pydantic import HttpUrl, SecretStr

from credential_usage.transport import DEADLINE_MARGIN, DirectHttp, HttpPolicy, HttpRequest, RequestFailure

BUDGET = 1.0


def trickle(listener: socket, stop: Event, sent: bytearray) -> None:
    """Answer one request with a six-second body sent one byte every 20 ms, so the client's socket timeout never fires."""
    with listener, listener.accept()[0] as connection:
        connection.recv(65536)
        connection.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 300\r\n\r\n")
        while len(sent) < 300 and not stop.wait(0.02):
            connection.sendall(b"x")
            sent.extend(b"x")


class DeadlineTests(unittest.TestCase):
    def test_direct_http_stops_waiting_at_the_deadline(self) -> None:
        """127. A trickling reply never trips the socket timeout, so without the caller's wait the request runs to the reply's end."""
        stop, sent = Event(), bytearray()
        with socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            url = HttpUrl(f"http://127.0.0.1:{listener.getsockname()[1]}/usage")
            Thread(target=trickle, args=(listener, stop, sent), daemon=True).start()
            client = DirectHttp(url, SecretStr("local-only"), HttpPolicy(timeout=30), time.monotonic() + BUDGET + DEADLINE_MARGIN)
            started = time.monotonic()
            with self.assertRaises(RequestFailure):
                client.request(HttpRequest(method="POST", url=url, body="query"))
            elapsed = time.monotonic() - started
            stop.set()
        self.assertLess(elapsed, BUDGET * 2.5)
        self.assertTrue(sent, "the reply never reached its trickling body")


if __name__ == "__main__":
    unittest.main()
