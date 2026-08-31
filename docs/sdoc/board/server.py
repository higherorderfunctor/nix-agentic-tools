#!/usr/bin/env python3
"""Serve one in-memory StrictDoc snapshot and the read-only board client."""

from __future__ import annotations

import argparse
import json
import mimetypes
import sys
import threading
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

from paths import default_socket_path, find_project_root
from rpc import RpcServer, build_rpc_server
from workspace import Workspace

HERE = Path(__file__).resolve().parent
STATIC_ROUTES = {
    "/": HERE / "index.html",
    "/index.html": HERE / "index.html",
    "/assets/board.css": HERE / "assets" / "board.css",
    "/assets/board.js": HERE / "assets" / "board.js",
    "/assets/layout.js": HERE / "assets" / "layout.js",
}
mimetypes.add_type("text/javascript", ".js")


class BoardServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address: tuple[str, int], workspace: Workspace):
        super().__init__(address, BoardHandler)
        self.workspace = workspace


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
            state = self.server.workspace.current()
            self._respond(
                HTTPStatus.OK,
                "application/json; charset=utf-8",
                state.payload,
                include_body=include_body,
                cache="no-store",
                generation=state.number,
            )
            return
        if path == "/api/health":
            body = json.dumps(
                {"ok": True, **self.server.workspace.describe()},
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
        generation: int | None = None,
    ) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        if generation is not None:
            self.send_header("X-SDoc-Board-Generation", str(generation))
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; connect-src 'self' ws:; img-src 'self' data:; "
            "style-src 'self'; script-src 'self'; object-src 'none'; base-uri 'none'",
        )
        self.end_headers()
        if include_body:
            self.wfile.write(body)


def build_server(workspace: Workspace, host: str, port: int) -> BoardServer:
    return BoardServer((host, port), workspace)


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
    parser.add_argument(
        "--state-dir",
        type=Path,
        help="persistent board state directory (default: derived from root)",
    )
    parser.add_argument(
        "--socket",
        type=Path,
        help="local JSON-RPC Unix socket (default: derived from root)",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    project_root = find_project_root(args.root)
    workspace = Workspace(project_root, args.state_dir)
    print(f"sdoc-board: loading {project_root}", flush=True)
    state = workspace.hydrate()
    server = build_server(workspace, args.host, args.port)
    socket_path = args.socket or default_socket_path(project_root)
    rpc_server: RpcServer | None = None
    rpc_thread: threading.Thread | None = None
    try:
        rpc_server = build_rpc_server(workspace, socket_path)
        rpc_thread = threading.Thread(target=rpc_server.serve_forever, daemon=True)
        rpc_thread.start()
    except BaseException:
        server.server_close()
        raise
    host, port = server.server_address[:2]
    stats = state.loaded.snapshot["stats"]
    hydration = state.loaded.hydration.as_dict()
    print(
        f"sdoc-board: http://{host}:{port}/ "
        f"({stats['nodes']} nodes, {stats['edges']} relations, "
        f"hydrated in {hydration['totalMs']:.1f} ms)",
        flush=True,
    )
    print(f"sdoc-board: state {workspace.state_dir}", flush=True)
    print(f"sdoc-board: rpc {socket_path}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nsdoc-board: stopping", flush=True)
    finally:
        server.server_close()
        if rpc_server is not None:
            rpc_server.shutdown()
            rpc_server.server_close()
        if rpc_thread is not None:
            rpc_thread.join(timeout=5)
    return 0


if __name__ == "__main__":
    sys.exit(main())
