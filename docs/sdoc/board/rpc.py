#!/usr/bin/env python3
"""Serve read-only workspace control as JSON-RPC 2.0 over a Unix socket."""

from __future__ import annotations

import json
import os
import socket
import socketserver
import stat
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from workspace import Workspace

RPC_SCHEMA = "sdoc-board-rpc/1"
MAX_REQUEST_BYTES = 16 * 1024 * 1024
METHODS = (
    "daemon.ping",
    "rpc.discover",
    "workspace.describe",
    "workspace.reload",
    "workspace.snapshot",
)


@dataclass(frozen=True)
class RpcFault(Exception):
    code: int
    message: str
    data: Any = None


def dispatch(workspace: Workspace, request: Any) -> dict[str, Any] | None:
    """Validate and execute one JSON-RPC request."""
    if not isinstance(request, dict) or request.get("jsonrpc") != "2.0":
        raise RpcFault(-32600, "Invalid Request")
    method = request.get("method")
    if not isinstance(method, str):
        raise RpcFault(-32600, "Invalid Request")
    request_id = request.get("id")
    is_notification = "id" not in request
    params = request.get("params")
    if params not in (None, [], {}):
        raise RpcFault(-32602, "Invalid params", "methods accept no parameters")

    if method == "daemon.ping":
        result: Any = {"ok": True}
    elif method == "rpc.discover":
        result = {
            "schema": RPC_SCHEMA,
            "framing": "one-json-value-per-newline",
            "canonicalMutation": False,
            "methods": list(METHODS),
        }
    elif method == "workspace.describe":
        result = workspace.describe()
    elif method == "workspace.snapshot":
        result = workspace.current().loaded.snapshot
    elif method == "workspace.reload":
        workspace.reload()
        result = workspace.describe()
    else:
        raise RpcFault(-32601, "Method not found", method)

    if is_notification:
        return None
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


def error_response(request_id: Any, fault: RpcFault) -> dict[str, Any]:
    error: dict[str, Any] = {"code": fault.code, "message": fault.message}
    if fault.data is not None:
        error["data"] = fault.data
    return {"jsonrpc": "2.0", "id": request_id, "error": error}


def handle_message(workspace: Workspace, message: bytes) -> bytes | None:
    """Decode one framed message and return one framed response."""
    request_id: Any = None
    try:
        request = json.loads(message)
        if isinstance(request, dict):
            request_id = request.get("id")
        response = dispatch(workspace, request)
    except json.JSONDecodeError as exception:
        response = error_response(None, RpcFault(-32700, "Parse error", str(exception)))
    except RpcFault as fault:
        response = error_response(request_id, fault)
    except Exception:
        response = error_response(request_id, RpcFault(-32603, "Internal error"))
    if response is None:
        return None
    return (
        json.dumps(response, ensure_ascii=False, separators=(",", ":")) + "\n"
    ).encode("utf-8")


class RpcHandler(socketserver.StreamRequestHandler):
    server: "RpcServer"

    def handle(self) -> None:
        while message := self.rfile.readline(MAX_REQUEST_BYTES + 1):
            if len(message) > MAX_REQUEST_BYTES:
                response = error_response(
                    None, RpcFault(-32600, "Invalid Request", "request too large")
                )
                self.wfile.write(
                    (
                        json.dumps(response, separators=(",", ":")) + "\n"
                    ).encode("utf-8")
                )
                return
            response = handle_message(self.server.workspace, message)
            if response is not None:
                self.wfile.write(response)


class RpcServer(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True

    def __init__(self, socket_path: Path, workspace: Workspace):
        self.socket_path = socket_path.expanduser().resolve()
        self.workspace = workspace
        _prepare_socket_path(self.socket_path)
        super().__init__(str(self.socket_path), RpcHandler)
        os.chmod(self.socket_path, 0o600)
        self._socket_inode = self.socket_path.stat().st_ino

    def server_close(self) -> None:
        super().server_close()
        try:
            socket_stat = self.socket_path.lstat()
        except FileNotFoundError:
            return
        if stat.S_ISSOCK(socket_stat.st_mode) and socket_stat.st_ino == self._socket_inode:
            self.socket_path.unlink()


def _prepare_socket_path(socket_path: Path) -> None:
    encoded_path = os.fsencode(socket_path)
    if len(encoded_path) >= 104:
        raise ValueError(f"Unix socket path is too long: {socket_path}")

    parent = socket_path.parent
    parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    parent_stat = parent.stat()
    if parent_stat.st_uid != os.getuid():
        raise PermissionError(f"Unix socket directory has another owner: {parent}")
    if stat.S_IMODE(parent_stat.st_mode) & 0o077:
        raise PermissionError(f"Unix socket directory must be mode 0700: {parent}")

    try:
        socket_stat = socket_path.lstat()
    except FileNotFoundError:
        return
    if not stat.S_ISSOCK(socket_stat.st_mode):
        raise FileExistsError(f"refusing to replace non-socket path: {socket_path}")

    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    probe.settimeout(0.2)
    try:
        probe.connect(str(socket_path))
    except (ConnectionRefusedError, FileNotFoundError):
        socket_path.unlink(missing_ok=True)
    else:
        raise RuntimeError(f"another sdoc-board owns {socket_path}")
    finally:
        probe.close()


def build_rpc_server(workspace: Workspace, socket_path: Path) -> RpcServer:
    return RpcServer(socket_path, workspace)
