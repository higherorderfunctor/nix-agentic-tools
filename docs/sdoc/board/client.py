#!/usr/bin/env python3
"""Call the resident sdoc-board workspace over its local JSON-RPC socket."""

from __future__ import annotations

import argparse
import json
import socket
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from paths import default_socket_path, find_project_root

MAX_RESPONSE_BYTES = 64 * 1024 * 1024
COMMAND_METHODS = {
    "discover": "rpc.discover",
    "info": "workspace.describe",
    "ping": "daemon.ping",
    "reload": "workspace.reload",
    "snapshot": "workspace.snapshot",
}


@dataclass(frozen=True)
class RpcClientError(Exception):
    code: int
    message: str
    data: Any = None

    def __str__(self) -> str:
        detail = f": {self.data}" if self.data is not None else ""
        return f"JSON-RPC {self.code} {self.message}{detail}"


def rpc_call(socket_path: Path, method: str, request_id: Any = 1) -> Any:
    request = {
        "jsonrpc": "2.0",
        "id": request_id,
        "method": method,
    }
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        connection.connect(str(socket_path))
        connection.sendall(
            (json.dumps(request, separators=(",", ":")) + "\n").encode("utf-8")
        )
        with connection.makefile("rb") as reader:
            response_bytes = reader.readline(MAX_RESPONSE_BYTES + 1)
    finally:
        connection.close()
    if not response_bytes:
        raise RpcClientError(-32000, "daemon closed without a response")
    if len(response_bytes) > MAX_RESPONSE_BYTES:
        raise RpcClientError(-32000, "daemon response is too large")
    response = json.loads(response_bytes)
    if response.get("id") != request_id:
        raise RpcClientError(-32000, "response id does not match request")
    if error := response.get("error"):
        raise RpcClientError(error["code"], error["message"], error.get("data"))
    return response["result"]


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path.cwd(),
        help="StrictDoc project or a path below it (default: cwd)",
    )
    parser.add_argument("--socket", type=Path, help="override the Unix socket path")
    parser.add_argument("command", choices=sorted(COMMAND_METHODS))
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        socket_path = args.socket
        if socket_path is None:
            socket_path = default_socket_path(find_project_root(args.root))
        result = rpc_call(socket_path, COMMAND_METHODS[args.command])
    except (FileNotFoundError, OSError, RpcClientError, ValueError) as exception:
        print(f"sdoc-board: {exception}", file=sys.stderr)
        return 1
    json.dump(result, sys.stdout, ensure_ascii=False, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
