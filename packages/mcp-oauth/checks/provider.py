"""Loopback form-capturing provider shared by OAuth scenarios."""

import contextlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import threading
from urllib.parse import parse_qs


def profile(token_url="http://127.0.0.1:1/token"):
    return {
        "authorizeUrl": "https://consent.example/authorize?audience=fixture&empty=",
        "extraScopes": ["keys:read"],
        "loginLifetimeDays": 30,
        "tokenUrl": token_url,
    }


def response(**changes):
    return dict({
        "access_token": "access-new",
        "expires_in": 1209600,
        "refresh_token": "refresh-original",
        "refresh_token_expires_in": 2592000,
        "scope": "keys:read messages:read rooms:read",
        "token_type": "Bearer",
    }, **changes)


class Provider(BaseHTTPRequestHandler):
    body = None
    calls = []
    grants = []
    reject = False
    reply = None
    unavailable = False

    def log_message(self, *_args):
        pass

    def do_POST(self):
        form = parse_qs(self.rfile.read(int(self.headers["Content-Length"])).decode())
        type(self).grants.append(form)
        type(self).calls.append((self.path, form, self.headers["Content-Type"]))
        status, body = self.reply or (
            (503, {"error": "temporarily_unavailable"}) if self.unavailable else
            (400, {"error": "invalid_grant"}) if self.reject else
            (200, self.body or response(access_token="access-" + str(len(self.grants)),
                           refresh_token="refresh-private", scope="keys:read messages:read")))
        raw = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


@contextlib.contextmanager
def provider(body=None, status=200):
    class Handler(Provider):
        calls = []
        grants = []
        reply = (status, response() if body is None else body)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}/v1/access_token", Handler.calls
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
