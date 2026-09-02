#!/usr/bin/env python3
"""Serve the read-only board app over the resident scribe daemon.

One stdlib HTTP server, GET and HEAD only, with an allowlisted static
surface and three JSON routes:

  /api/health   the daemon's describe (or the refusal, see below)
  /api/graph    sdoc-board/2 -- the Board canvas snapshot
  /api/rows     sdoc-perspective/2 -- the explorer's two tables

Data is the daemon's, via DaemonSource; this process never imports strictdoc
and holds no graph. No daemon answering is HTTP 503 with the client's own
remedy in the body -- the browser shows it and offers a retry, rather than
this server quietly loading the corpus itself.

The Content-Security-Policy admits cdn.jsdelivr.net, blob: scripts and
workers, and wasm-unsafe-eval: Perspective's pinned CDN build loads its wasm
and worker that way (EV-SDOC-PERSPECTIVE-FIRST-EXPLORER measured exactly
which directives it needs; the board view alone needs none of them).
"""

from __future__ import annotations

import argparse
import json
import mimetypes
import sys
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parents[2] / "dev" / "scripts"))

from scribe_paths import RootError, resolve_root  # noqa: E402

from source import ClientError, DaemonSource, NoDaemon  # noqa: E402

STATIC_ROUTES = {
    "/": HERE / "index.html",
    "/index.html": HERE / "index.html",
    "/grammar-groups.json": HERE / "grammar-groups.json",
    "/assets/app.css": HERE / "assets" / "app.css",
    "/assets/app.js": HERE / "assets" / "app.js",
    "/assets/board.js": HERE / "assets" / "board.js",
    "/assets/card.js": HERE / "assets" / "card.js",
    "/assets/grammars.js": HERE / "assets" / "grammars.js",
    "/assets/plan.js": HERE / "assets" / "plan.js",
    "/assets/layout.js": HERE / "assets" / "layout.js",
    "/assets/perspective.js": HERE / "assets" / "perspective.js",
    "/assets/theme.css": HERE / "assets" / "theme.css",
}
CONTENT_SECURITY_POLICY = (
    "default-src 'self'; "
    "connect-src 'self' https://cdn.jsdelivr.net; "
    "font-src 'self' https://cdn.jsdelivr.net data:; "
    "img-src 'self' https://cdn.jsdelivr.net data:; "
    "object-src 'none'; base-uri 'none'; "
    "script-src 'self' https://cdn.jsdelivr.net blob: 'wasm-unsafe-eval'; "
    "style-src 'self' https://cdn.jsdelivr.net 'unsafe-inline'; "
    "worker-src 'self' https://cdn.jsdelivr.net blob:"
)
mimetypes.add_type("text/javascript", ".js")


class BoardServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address: tuple[str, int], source: DaemonSource):
        super().__init__(address, BoardHandler)
        self.source = source


class BoardHandler(BaseHTTPRequestHandler):
    server: BoardServer

    def do_HEAD(self) -> None:
        self._serve(include_body=False)

    def do_GET(self) -> None:
        self._serve(include_body=True)

    def do_POST(self) -> None:
        self._method_not_allowed()

    def do_PUT(self) -> None:
        self._method_not_allowed()

    def do_PATCH(self) -> None:
        self._method_not_allowed()

    def do_DELETE(self) -> None:
        self._method_not_allowed()

    def _method_not_allowed(self) -> None:
        self.send_response(HTTPStatus.METHOD_NOT_ALLOWED)
        self.send_header("Allow", "GET, HEAD")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _serve(self, *, include_body: bool) -> None:
        path = urlsplit(self.path).path
        if path == "/api/health":
            self._api(include_body, lambda s: _json_bytes({"ok": True, **s.describe()}))
            return
        if path == "/api/graph":
            self._api(include_body, lambda s: s.payloads().snapshot)
            return
        if path == "/api/rows":
            self._api(include_body, lambda s: s.payloads().rows)
            return

        asset = STATIC_ROUTES.get(path)
        if asset is None or not asset.is_file():
            self._respond(
                HTTPStatus.NOT_FOUND,
                "text/plain; charset=utf-8",
                b"not found\n",
                include_body=include_body,
            )
            return
        media_type = mimetypes.guess_type(asset.name)[0] or "application/octet-stream"
        self._respond(
            HTTPStatus.OK,
            f"{media_type}; charset=utf-8"
            if media_type.startswith(("text/", "application/javascript"))
            else media_type,
            asset.read_bytes(),
            include_body=include_body,
        )

    def _api(self, include_body: bool, produce) -> None:
        try:
            body = produce(self.server.source)
        except NoDaemon as refusal:
            self._respond(
                HTTPStatus.SERVICE_UNAVAILABLE,
                "application/json; charset=utf-8",
                _json_bytes({"error": "no-daemon", "detail": str(refusal)}),
                include_body=include_body,
                cache="no-store",
            )
            return
        except ClientError as error:
            self._respond(
                HTTPStatus.BAD_GATEWAY,
                "application/json; charset=utf-8",
                _json_bytes({"error": "daemon-error", "detail": str(error)}),
                include_body=include_body,
                cache="no-store",
            )
            return
        self._respond(
            HTTPStatus.OK,
            "application/json; charset=utf-8",
            body,
            include_body=include_body,
            cache="no-store",
        )

    def _respond(
        self,
        status: HTTPStatus,
        content_type: str,
        body: bytes,
        *,
        include_body: bool,
        cache: str = "no-cache",
    ) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache)
        self.send_header("Content-Security-Policy", CONTENT_SECURITY_POLICY)
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        if include_body:
            self.wfile.write(body)


def _json_bytes(payload: dict) -> bytes:
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode(
        "utf-8"
    )


def build_server(source: DaemonSource, host: str, port: int) -> BoardServer:
    return BoardServer((host, port), source)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="sdoc-board", description=__doc__)
    parser.add_argument(
        "--root",
        help="the workspace to serve (default: $SCRIBE_ROOT, then the walk up from cwd)",
    )
    parser.add_argument("--host", default="127.0.0.1", help="bind address")
    parser.add_argument("--port", type=int, default=8765, help="bind port")
    parser.add_argument("--socket", help="override the daemon's derived socket path")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        root = resolve_root(args.root)
    except RootError as exc:
        print(f"sdoc-board: {exc}", file=sys.stderr)
        return 1
    source = DaemonSource(root, socket_override=args.socket)
    server = build_server(source, args.host, args.port)
    host, port = server.server_address[:2]
    print(f"sdoc-board: http://{host}:{port}/ over {root}", flush=True)
    try:
        described = source.describe()
        print(
            f"sdoc-board: daemon holds {described['nodes']} nodes "
            f"(generation {described['generation']})",
            flush=True,
        )
    except ClientError as exc:
        print(f"sdoc-board: {exc}", file=sys.stderr)
        print("sdoc-board: serving anyway; the page will say so", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nsdoc-board: stopping", flush=True)
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
