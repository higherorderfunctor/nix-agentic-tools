#!/usr/bin/env python3
"""Serve one in-memory StrictDoc snapshot and the read-only board client."""

from __future__ import annotations

import argparse
import json
import mimetypes
import sys
import tempfile
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

from snapshot import LoadedProject, find_project_root, load_project

HERE = Path(__file__).resolve().parent
STATIC_ROUTES = {
    "/": HERE / "index.html",
    "/index.html": HERE / "index.html",
    "/assets/board.css": HERE / "assets" / "board.css",
    "/assets/board.js": HERE / "assets" / "board.js",
    "/assets/layout.js": HERE / "assets" / "layout.js",
}
mimetypes.add_type("text/javascript", ".js")


class SnapshotStore:
    """The seam a future watcher swaps and a WebSocket broadcaster observes."""

    def __init__(self, loaded: LoadedProject):
        self.loaded = loaded
        self.payload = json.dumps(
            loaded.snapshot, ensure_ascii=False, separators=(",", ":")
        ).encode("utf-8")


class BoardServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address: tuple[str, int], store: SnapshotStore):
        super().__init__(address, BoardHandler)
        self.store = store


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
        if path == "/api/graph":
            self._respond(
                HTTPStatus.OK,
                "application/json; charset=utf-8",
                self.server.store.payload,
                include_body=include_body,
                cache="no-store",
            )
            return
        if path == "/api/health":
            snapshot = self.server.store.loaded.snapshot
            body = json.dumps(
                {
                    "ok": True,
                    "schema": snapshot["schema"],
                    "snapshotHash": snapshot["project"]["snapshotHash"],
                },
                separators=(",", ":"),
            ).encode("utf-8")
            self._respond(
                HTTPStatus.OK,
                "application/json; charset=utf-8",
                body,
                include_body=include_body,
                cache="no-store",
            )
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
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; connect-src 'self' ws:; img-src 'self' data:; "
            "style-src 'self'; script-src 'self'; object-src 'none'; base-uri 'none'",
        )
        self.end_headers()
        if include_body:
            self.wfile.write(body)


def build_server(store: SnapshotStore, host: str, port: int) -> BoardServer:
    return BoardServer((host, port), store)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path.cwd(),
        help="StrictDoc project or a path below it (default: cwd)",
    )
    parser.add_argument("--host", default="127.0.0.1", help="bind address")
    parser.add_argument("--port", type=int, default=8765, help="bind port")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    project_root = find_project_root(args.root)
    with tempfile.TemporaryDirectory(prefix="sdoc-board-") as cache:
        print(f"sdoc-board: loading {project_root}", flush=True)
        loaded = load_project(project_root, Path(cache))
        store = SnapshotStore(loaded)
        server = build_server(store, args.host, args.port)
        host, port = server.server_address[:2]
        stats = loaded.snapshot["stats"]
        print(
            f"sdoc-board: http://{host}:{port}/ "
            f"({stats['nodes']} nodes, {stats['edges']} relations)",
            flush=True,
        )
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            print("\nsdoc-board: stopping", flush=True)
        finally:
            server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
