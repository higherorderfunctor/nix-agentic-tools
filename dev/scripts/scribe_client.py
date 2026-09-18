#!/usr/bin/env python3
# cspell:ignore sdoc
"""Talk to a scribe daemon, and fail when there isn't one
(REQ-SCRIBE-CLIENT-FAILS-CLOSED, docs/plans/scribe-daemon/).

No strictdoc import: this has to run from anywhere, and paying a parser import
to ask "is the daemon up?" would defeat the point. It is NOT standard-library
only any more -- pydantic types the reply envelope (see below) -- which is why
scribe_cmd imports this module inside main() rather than at the top: printing
`--help` should not cost an import the help text does not use.

THERE IS NO FALLBACK, AND THAT IS THE FEATURE
---------------------------------------------
When no daemon answers this exits non-zero naming the socket and the command
that starts one. It does NOT load the graph itself, does not start a daemon,
and does not answer from a cache (DEC-SCRIBE-DAEMON-NO-FALLBACK).

A silent in-process fallback would turn ten reads into thirty seconds spread
across ten invocations that each look normal. A refusal costs one
interruption. The operator, or later the harness, is the scheduler; being
told is the point.

EVERY MALFORMED REPLY IS A ClientError, NEVER A TRACEBACK
----------------------------------------------------------
The reply used to be read with `json.loads` and then indexed:
`response["result"]` raised KeyError on a reply with neither result nor error,
`error["code"]` raised on an error that was not an object, and a non-dict
result silently SKIPPED the served-root assertion below -- which is the one
check standing between a misdirected socket and another worktree's canon
answering as if it were yours.

So the envelope goes through a pydantic model: exactly one of `result` and
`error` present, `code` an int, `message` a string, nothing else in the
object. Every failure of that shape names what was wrong.

    scribe-client ping | info | reload | export --out DIR
"""

import argparse
import json
import socket
import sys
from pathlib import Path
from typing import Any

import pydantic

sys.path.insert(0, str(Path(__file__).resolve().parent))

from scribe_paths import RootError, resolve_root, socket_path  # noqa: E402

MAX_RESPONSE_BYTES = 64 * 1024 * 1024


class ClientError(Exception):
    """Anything the caller should print and exit non-zero on."""


class NoDaemon(ClientError):
    """Nothing is listening. Carries the remedy, not just the symptom."""


class _Error(pydantic.BaseModel):
    """A JSON-RPC error object, and nothing else pretending to be one."""

    model_config = pydantic.ConfigDict(extra="forbid", strict=True)

    code: int
    message: str
    data: Any = None


class _Envelope(pydantic.BaseModel):
    """A JSON-RPC 2.0 response, with `result` XOR `error` enforced.

    `model_fields_set` rather than a None check, because a method is allowed
    to answer `"result": null` and that is a SUCCESS, not a missing result.
    """

    model_config = pydantic.ConfigDict(extra="forbid", strict=True)

    jsonrpc: str
    id: int | str | None = None
    result: Any = None
    error: _Error | None = None

    @pydantic.model_validator(mode="after")
    def _exactly_one(self) -> "_Envelope":
        has_result = "result" in self.model_fields_set
        if has_result and self.error is not None:
            raise ValueError("carries both a result and an error")
        if not has_result and self.error is None:
            raise ValueError("carries neither a result nor an error")
        return self


def _describe(error: _Error) -> str:
    """`JSON-RPC -32602 Invalid params: dry_run: Input should be a valid
    boolean` -- the FIELD, not a wall of pydantic error dictionaries.

    pjrpc serializes a parameter-validation failure as the list of pydantic
    error records, which carry the one thing the caller needs (`loc`) buried
    among four things it does not. Flatten it; leave anything else alone.
    """
    data = error.data
    if isinstance(data, list) and all(
        isinstance(item, dict) and "loc" in item and "msg" in item for item in data
    ):
        detail = "; ".join(
            f"{'.'.join(str(part) for part in item['loc']) or 'params'}: {item['msg']}"
            for item in data
        )
    elif data is None:
        detail = ""
    else:
        detail = str(data)
    return f"JSON-RPC {error.code} {error.message}" + (f": {detail}" if detail else "")


def call(path: Path, method: str, params: dict | None = None, request_id: Any = 1) -> Any:
    """One request, one reply. `request_id` is deliberately untyped here: what
    JSON-RPC accepts as an id is the DAEMON's to enforce, and a contract test
    sends a wrong one on purpose to prove it does."""
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
    try:
        decoded = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ClientError(f"the daemon's reply is not JSON: {exc}") from exc
    try:
        response = _Envelope.model_validate(decoded)
    except pydantic.ValidationError as exc:
        raise ClientError(
            f"the daemon's reply is not a JSON-RPC response: "
            f"{'; '.join(_fault(item) for item in exc.errors())}"
        ) from exc

    if response.error is not None:
        # Reported BEFORE the id check on purpose: a parse or invalid-request
        # error legitimately carries `"id": null`, and refusing it as an id
        # mismatch would hide the fault the daemon actually named.
        raise ClientError(_describe(response.error))
    if response.id != request_id:
        raise ClientError(
            f"response id does not match the request: asked {request_id!r}, "
            f"answered {response.id!r}"
        )
    return response.result


def _fault(item: dict) -> str:
    location = ".".join(str(part) for part in item["loc"]) or "response"
    return f"{location}: {item['msg']}"


def call_for_root(root: Path, method: str, params: dict | None = None, *, override=None) -> Any:
    """Call, then ASSERT the daemon serves the workspace we asked about.

    Without this a stale or misdirected socket answers from another
    worktree's canon and looks entirely correct. The mismatch is loud
    instead.
    """
    path = socket_path(root, override=override)
    result = call(path, method, params)
    if not isinstance(result, dict):
        # This used to be `if isinstance(result, dict)`, which SKIPPED the
        # assertion below rather than failing it: a daemon answering a bare
        # string or list passed the one check that catches a misdirected
        # socket. Every method here answers with an object.
        raise ClientError(
            f"the daemon on {path} answered {method} with a "
            f"{type(result).__name__}, not an object"
        )
    served = result.get("root")
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
    sub.add_parser("reload", help="rebuild now rather than at the next read")
    export = sub.add_parser("export", help="write the export JSON from the held graph")
    export.add_argument("--out", required=True, help="output directory")
    return parser.parse_args(argv)


METHODS = {
    "ping": "daemon.ping",
    "info": "workspace.describe",
    "reload": "workspace.reload",
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
