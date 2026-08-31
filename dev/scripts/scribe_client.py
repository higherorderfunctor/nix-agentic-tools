#!/usr/bin/env python3
# cspell:ignore sdoc
"""Talk to a scribe daemon, and fail when there isn't one
(REQ-SCRIBE-CLIENT-FAILS-CLOSED, docs/plans/scribe-daemon/).

Stdlib only, and no strictdoc import: this has to run from anywhere, and
paying a parser import to ask "is the daemon up?" would defeat the point.

THERE IS NO FALLBACK, AND THAT IS THE FEATURE
---------------------------------------------
When no daemon answers this exits non-zero naming the socket and the command
that starts one. It does NOT load the graph itself, does not start a daemon,
and does not answer from a cache (DEC-SCRIBE-DAEMON-NO-FALLBACK).

A silent in-process fallback would turn ten reads into thirty seconds spread
across ten invocations that each look normal. A refusal costs one
interruption. The operator, or later the harness, is the scheduler; being
told is the point.

    scribe-client ping | info | reconcile | export --out DIR
"""

from __future__ import annotations

import argparse
import json
import socket
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from scribe_paths import RootError, resolve_root, socket_path  # noqa: E402

MAX_RESPONSE_BYTES = 64 * 1024 * 1024


class ClientError(Exception):
    """Anything the caller should print and exit non-zero on."""


class NoDaemon(ClientError):
    """Nothing is listening. Carries the remedy, not just the symptom."""


def call(path: Path, method: str, params: dict | None = None, request_id: int = 1) -> Any:
    request = {"jsonrpc": "2.0", "id": request_id, "method": method}
    if params:
        request["params"] = params
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        try:
            connection.connect(str(path))
        except (FileNotFoundError, ConnectionRefusedError) as exc:
            raise NoDaemon(
                f"no scribe daemon on {path}.\n"
                f"  start one with:  devenv up scribe\n"
                f"  or directly:     scribe-daemon --root <worktree>"
            ) from exc
        connection.sendall((json.dumps(request, separators=(",", ":")) + "\n").encode("utf-8"))
        with connection.makefile("rb") as reader:
            raw = reader.readline(MAX_RESPONSE_BYTES + 1)
    finally:
        connection.close()

    if not raw:
        raise ClientError("the daemon closed the connection without answering")
    if len(raw) > MAX_RESPONSE_BYTES:
        raise ClientError("the daemon's response is too large")
    response = json.loads(raw)
    if response.get("id") != request_id:
        raise ClientError("response id does not match the request")
    if error := response.get("error"):
        detail = f": {error['data']}" if error.get("data") is not None else ""
        raise ClientError(f"JSON-RPC {error['code']} {error['message']}{detail}")
    return response["result"]


def call_for_root(root: Path, method: str, params: dict | None = None, *, override=None) -> Any:
    """Call, then ASSERT the daemon serves the workspace we asked about.

    Without this a stale or misdirected socket answers from another
    worktree's canon and looks entirely correct. The mismatch is loud
    instead.
    """
    path = socket_path(root, override=override)
    result = call(path, method, params)
    served = result.get("root") if isinstance(result, dict) else None
    if served is not None and Path(served).resolve() != Path(root).resolve():
        raise ClientError(
            f"the daemon on {path} serves {served}, not {root} -- refusing to "
            f"answer from another workspace's canon"
        )
    return result


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="scribe-client", description=__doc__)
    parser.add_argument("--root", help="the workspace (default: $SCRIBE_ROOT, then cwd)")
    parser.add_argument("--socket", help="override the derived socket path")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("ping", help="is a daemon serving this workspace?")
    sub.add_parser("info", help="what the daemon holds")
    sub.add_parser("reconcile", help="rebuild now rather than at the next read")
    export = sub.add_parser("export", help="write the export JSON from the held graph")
    export.add_argument("--out", required=True, help="output directory")
    return parser.parse_args(argv)


METHODS = {
    "ping": "daemon.ping",
    "info": "workspace.describe",
    "reconcile": "workspace.reconcile",
    "export": "workspace.export",
}


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        root = resolve_root(args.root)
        params = {"outputDir": str(Path(args.out).expanduser().resolve())} if args.command == "export" else None
        result = call_for_root(root, METHODS[args.command], params, override=args.socket)
    except (ClientError, RootError) as exc:
        print(f"scribe: {exc}", file=sys.stderr)
        return 1
    json.dump(result, sys.stdout, ensure_ascii=False, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
