#!/usr/bin/env python3
# cspell:ignore sdoc uids
"""JSON-RPC 2.0 over one Unix socket, in front of one held workspace
(MECH-SCRIBE-RPC, docs/plans/scribe-daemon/).

The transport owns no state and parses nothing. Every method delegates to a
Workspace, which is what lets a second transport be added later without
touching workspace semantics.

FRAMING is one JSON value per newline, which keeps the client a dozen lines
of stdlib and means a person can drive it with `socat` when something is
wrong.

OWNERSHIP. On start the server probes any socket already at its path:
refused or absent means a dead daemon left it behind, and it is replaced; a
successful connect means a live daemon already owns this workspace, and
starting a second one is refused rather than silently stealing the path. On
stop the socket is unlinked only if its inode is still the one that was
bound, so a racing restart does not have its socket deleted by the process it
replaced.

EVERY REPLY CARRIES THE SERVED ROOT. A client asserts it matches what it
asked for, so a stale or misdirected socket is a loud mismatch instead of
another worktree's canon answering as if it were yours.
"""

from __future__ import annotations

import json
import os
import socket
import socketserver
import stat
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from scribe_workspace import Workspace, WorkspaceError  # noqa: E402

SCHEMA = "scribe-rpc/1"
MAX_REQUEST_BYTES = 16 * 1024 * 1024
METHODS = (
    "daemon.ping",
    "rpc.discover",
    "workspace.describe",
    "workspace.export",
    "workspace.reload",
)


@dataclass(frozen=True)
class RpcFault(Exception):
    code: int
    message: str
    data: Any = None


def dispatch(workspace: Workspace, request: Any) -> dict[str, Any] | None:
    if not isinstance(request, dict) or request.get("jsonrpc") != "2.0":
        raise RpcFault(-32600, "Invalid Request")
    method = request.get("method")
    if not isinstance(method, str):
        raise RpcFault(-32600, "Invalid Request")
    params = request.get("params") or {}
    if not isinstance(params, dict):
        raise RpcFault(-32602, "Invalid params", "params must be an object")
    is_notification = "id" not in request

    try:
        result = _call(workspace, method, params)
    except RpcFault:
        raise
    except WorkspaceError as exc:
        raise RpcFault(-32001, "Workspace error", str(exc)) from exc

    if is_notification:
        return None
    return {"jsonrpc": "2.0", "id": request.get("id"), "result": result}


def _call(workspace: Workspace, method: str, params: dict) -> Any:
    if method == "daemon.ping":
        return {"ok": True, "root": str(workspace.root)}
    if method == "rpc.discover":
        return {
            "schema": SCHEMA,
            "framing": "one-json-value-per-newline",
            "root": str(workspace.root),
            "methods": list(METHODS),
        }
    if method == "workspace.describe":
        return workspace.describe()
    if method == "workspace.reload":
        workspace.reload()
        return workspace.describe()
    if method == "workspace.export":
        output_dir = params.get("outputDir")
        if not output_dir:
            raise RpcFault(-32602, "Invalid params", "workspace.export needs outputDir")
        return workspace.export_json(Path(output_dir))
    raise RpcFault(-32601, "Method not found", method)


def error_response(request_id: Any, fault: RpcFault) -> dict[str, Any]:
    error: dict[str, Any] = {"code": fault.code, "message": fault.message}
    if fault.data is not None:
        error["data"] = fault.data
    return {"jsonrpc": "2.0", "id": request_id, "error": error}


def handle_message(workspace: Workspace, message: bytes) -> bytes | None:
    request_id: Any = None
    try:
        request = json.loads(message)
        if isinstance(request, dict):
            request_id = request.get("id")
        response = dispatch(workspace, request)
    except json.JSONDecodeError as exc:
        response = error_response(None, RpcFault(-32700, "Parse error", str(exc)))
    except RpcFault as fault:
        response = error_response(request_id, fault)
    except Exception as exc:  # noqa: BLE001 -- a daemon answers, it does not die
        response = error_response(request_id, RpcFault(-32603, "Internal error", str(exc)))
    if response is None:
        return None
    return (json.dumps(response, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")


class RpcHandler(socketserver.StreamRequestHandler):
    server: "RpcServer"

    def handle(self) -> None:
        while message := self.rfile.readline(MAX_REQUEST_BYTES + 1):
            if len(message) > MAX_REQUEST_BYTES:
                self.wfile.write(
                    (
                        json.dumps(
                            error_response(None, RpcFault(-32600, "Invalid Request", "too large")),
                            separators=(",", ":"),
                        )
                        + "\n"
                    ).encode("utf-8")
                )
                return
            reply = handle_message(self.server.workspace, message)
            if reply is not None:
                self.wfile.write(reply)


class RpcServer(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True
    allow_reuse_address = False

    def __init__(self, socket_path: Path, workspace: Workspace) -> None:
        self.socket_path = Path(socket_path).expanduser()
        self.workspace = workspace
        prepare_socket_path(self.socket_path)
        super().__init__(str(self.socket_path), RpcHandler)
        os.chmod(self.socket_path, 0o600)
        self._inode = self.socket_path.stat().st_ino

    def server_close(self) -> None:
        super().server_close()
        try:
            info = self.socket_path.lstat()
        except FileNotFoundError:
            return
        if stat.S_ISSOCK(info.st_mode) and info.st_ino == self._inode:
            self.socket_path.unlink(missing_ok=True)


def prepare_socket_path(path: Path) -> None:
    """Make the directory safe, and refuse to displace a live owner."""
    if len(os.fsencode(path)) >= 104:
        raise ValueError(f"socket path is too long for sockaddr_un: {path}")
    parent = path.parent
    parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = parent.stat()
    if info.st_uid != os.getuid():
        raise PermissionError(f"socket directory belongs to another user: {parent}")
    if stat.S_IMODE(info.st_mode) & 0o077:
        raise PermissionError(f"socket directory must be mode 0700: {parent}")

    try:
        existing = path.lstat()
    except FileNotFoundError:
        return
    if not stat.S_ISSOCK(existing.st_mode):
        raise FileExistsError(f"refusing to replace a non-socket path: {path}")

    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    probe.settimeout(0.2)
    try:
        probe.connect(str(path))
    except (ConnectionRefusedError, FileNotFoundError):
        path.unlink(missing_ok=True)  # a dead daemon's leftover
    else:
        raise RuntimeError(f"another scribe daemon already owns {path}")
    finally:
        probe.close()


def build_server(workspace: Workspace, socket_path: Path) -> RpcServer:
    return RpcServer(socket_path, workspace)
