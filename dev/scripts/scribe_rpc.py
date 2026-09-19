#!/usr/bin/env python3
# cspell:ignore sdoc uids pjrpc jsonrpc
"""JSON-RPC 2.0 over one Unix socket, in front of one held workspace
(MECH-SCRIBE-RPC, docs/plans/scribe-daemon/).

The transport owns no state and parses nothing. Every method delegates to a
Workspace, which is what lets a second transport be added later without
touching workspace semantics.

FRAMING is one JSON value per newline. The client stays small and a person can
still drive the socket with `socat` when something is wrong.

THE ENVELOPE IS pjrpc'S, THE TRANSPORT IS OURS
-----------------------------------------------
`pjrpc.server.Dispatcher.dispatch(request_text, context)` is synchronous and
framework-free, so it drops into a threading Unix-socket server with no event
loop anywhere. It owns request parsing, the id and version rules, method
lookup, batch handling and error serialization -- about sixty lines of
hand-written envelope code that used to live here and that
WORK-RPC-ON-PJRPC-AND-PYDANTIC found twelve gaps in, five of them silent.

Everything around it is still ours and deliberately so: the AF_UNIX socket,
the newline framing, the 16 MiB request cap, the threading server, the derived
socket path, the ownership probe, and DEC-SCRIBE-DAEMON-NO-FALLBACK (no
autostart, no fallback, no cache).

EVERY METHOD IS TYPED, AND THE TYPING IS IN TWO LAYERS
-------------------------------------------------------
`PydanticValidatorFactory(strict=True)` builds a pydantic model from each
method's SIGNATURE, so an unknown parameter key is `-32602` naming the key and
a JSON string never arrives where a bool was declared. `scribe.apply` declares
the union of every operation's parameters, because one signature cannot say
"uid is required for `set` and meaningless for `check`"; scribe_ops.py owns
that second layer, one model per operation.

DO NOT ADD `from __future__ import annotations` TO THIS FILE. pjrpc builds its
validation models with `pydantic.create_model` from `inspect.signature`, and
under that import every annotation is a STRING that pydantic then tries to
resolve in its own module rather than this one. The failure is not subtle --
`PydanticUserError: RelationParams is not fully defined` on the first
`scribe.apply` -- but it is a long way from the import that caused it.

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

import functools
import json
import os
import socket
import socketserver
import stat
import sys
from pathlib import Path

from pjrpc.common import Response
from pjrpc.server import Dispatcher, MethodRegistry, exclude_named_param
from pjrpc.server import exceptions as rpc_exceptions
from pjrpc.server.validators.pydantic import PydanticValidatorFactory

sys.path.insert(0, str(Path(__file__).resolve().parent))

from scribe_contract import WorkspaceGrammarResult  # noqa: E402
from scribe_ops import LineRange, ParamsError, RelationParams  # noqa: E402
from scribe_ops import apply as apply_operation  # noqa: E402
from scribe_workspace import Workspace, WorkspaceError  # noqa: E402
from sdoc_model import SdocError, authoring_grammar  # noqa: E402

# Bumped from `scribe-rpc/1` when the envelope moved onto pjrpc. Same framing
# and socket; what changed is that a malformed request is now refused by name
# rather than absorbed, so a client written against /1 that was relying on a
# silently-dropped key starts seeing -32602. New methods carry their own result
# schema and do not change this envelope version.
SCHEMA = "scribe-rpc/2"

MAX_REQUEST_BYTES = 16 * 1024 * 1024

# Batches are ALLOWED, and small on purpose. pjrpc's Dispatcher runs them
# sequentially in the calling thread, and every write in this daemon is
# serialized behind one held graph, so a large batch is one thread holding the
# workspace for an unbounded time while other clients block. Eight is enough
# for the only real use -- a handful of related writes landing together -- and
# small enough that the refusal above it arrives as a refusal rather than as a
# timeout.
MAX_BATCH_SIZE = 8

# A read cap and a drain cap are different numbers. When a request line is over
# MAX_REQUEST_BYTES the server still has to consume it, because a client that
# is mid-write when its socket closes gets EPIPE and never sees the refusal it
# earned. This bounds that courtesy: past it the connection just closes, which
# is the right answer to something that is no longer a request.
MAX_DISCARD_BYTES = 4 * MAX_REQUEST_BYTES


class WorkspaceFault(rpc_exceptions.TypedError):
    """-32001. The workspace could not answer -- a load failure, a bad path."""

    CODE = -32001
    MESSAGE = "Workspace error"


class RefusedFault(rpc_exceptions.TypedError):
    """-32002. The operation was understood and DECLINED.

    Not a transport failure: the client prints it and exits 1, exactly as it
    would for the same refusal on the command line.
    """

    CODE = -32002
    MESSAGE = "Refused"


def _faults(method=None, *, workspace_fault=WorkspaceFault):
    """Turn this repository's refusals into the codes clients already know.

    WorkspaceError is a subclass of SdocError, so it is caught FIRST. A
    workspace.* method uses -32001 because its held workspace could not
    answer. scribe.apply selects RefusedFault instead: once the operation has
    reached the workspace, a validation failure or rejected save is an
    understood operation that was declined, as it was under scribe-rpc/1.
    """

    def decorate(target):
        @functools.wraps(target)
        def guarded(*args, **kwargs):
            try:
                return target(*args, **kwargs)
            except ParamsError as exc:
                raise rpc_exceptions.InvalidParamsError(data=str(exc)) from exc
            except WorkspaceError as exc:
                raise workspace_fault(data=str(exc)) from exc
            except SdocError as exc:
                raise RefusedFault(data=str(exc)) from exc
            except Exception as exc:
                # pjrpc catches method exceptions inside dispatch(), before
                # handle_message's outer safety net can see them. Preserve the
                # /1 contract: unexpected failures are -32603 and retain the
                # diagnostic the operator needs to act on them.
                raise rpc_exceptions.InternalError(data=str(exc)) from exc

        return guarded

    return decorate if method is None else decorate(method)


# `exclude` is not optional here, and its absence is silent. pjrpc derives one
# for `pass_context` only when a method carries NO validator factory; hand it
# one and the context parameter stays in the signature, so pydantic demands a
# `workspace` key in the params of every call. Every method below therefore
# names its context parameter `workspace`, and this excludes exactly that name.
REGISTRY = MethodRegistry(
    validator_factory=PydanticValidatorFactory(
        exclude=exclude_named_param("workspace"),
        strict=True,
    ),
)


@REGISTRY.add("daemon.ping", pass_context="workspace")
def daemon_ping(workspace: Workspace) -> dict:
    return {"ok": True, "root": str(workspace.root)}


@REGISTRY.add("rpc.discover", pass_context="workspace")
def rpc_discover(workspace: Workspace) -> dict:
    """What this socket speaks. `methods` is READ OFF THE REGISTRY rather than
    listed beside it, so the set that exists and the set that is advertised
    cannot drift apart."""
    return {
        "schema": SCHEMA,
        "framing": "one-json-value-per-newline",
        "root": str(workspace.root),
        "methods": sorted(REGISTRY.keys()),
    }


@REGISTRY.add("workspace.describe", pass_context="workspace")
@_faults
def workspace_describe(workspace: Workspace) -> dict:
    return workspace.describe()


@REGISTRY.add("workspace.reload", pass_context="workspace")
@_faults
def workspace_reload(workspace: Workspace) -> dict:
    workspace.reload()
    return workspace.describe()


@REGISTRY.add("workspace.export", pass_context="workspace")
@_faults
def workspace_export(workspace: Workspace, outputDir: str) -> dict:  # noqa: N803
    return workspace.export_json(Path(outputDir))


@REGISTRY.add("workspace.grammar", pass_context="workspace")
@_faults
def workspace_grammar(workspace: Workspace) -> dict:
    result = WorkspaceGrammarResult(types=authoring_grammar(workspace.current().graph.grammar))
    return result.model_dump(by_alias=True)


@REGISTRY.add("scribe.apply", pass_context="workspace")
@_faults(workspace_fault=RefusedFault)
def scribe_apply(
    workspace: Workspace,
    op: str,
    uid: str | None = None,
    type: str | None = None,
    path: str | None = None,
    fields: dict[str, str] | None = None,
    unset: list[str] | None = None,
    relations: list[RelationParams] | None = None,
    role: str | None = None,
    target: str | None = None,
    element: str | None = None,
    id: str | None = None,
    line_range: LineRange = None,
    status: str | None = None,
    dry_run: bool | None = None,
) -> dict:
    """The WIRE contract for every operation: which keys exist at all, and
    what JSON type each one carries. Which of them an operation REQUIRES, and
    which it forbids, is scribe_ops.PARAMS -- that module's header says why
    the two layers are not one.

    `type` and `id` shadow builtins on purpose: they are the names on the wire
    and in the grammar, and renaming them here would rename them there.

    A parameter left at its default is DROPPED rather than passed on as None,
    so the operation's own model sees the payload the client actually sent and
    its own defaults apply. That is why `dry_run` defaults to None here and to
    False in scribe_ops: a `False` injected by this layer would reach `show`,
    which declares no `dry_run`, and be refused as an extra key on a payload
    the client never sent it on.
    """
    payload = {
        "op": op,
        "uid": uid,
        "type": type,
        "path": path,
        "fields": fields,
        "unset": unset,
        "relations": (
            [relation.model_dump() for relation in relations] if relations is not None else None
        ),
        "role": role,
        "target": target,
        "element": element,
        "id": id,
        "line_range": line_range,
        "status": status,
        "dry_run": dry_run,
    }
    return apply_operation(
        workspace,
        op,
        {name: value for name, value in payload.items() if value is not None},
    )


DISPATCHER: Dispatcher = Dispatcher(max_batch_size=MAX_BATCH_SIZE)
DISPATCHER.add_methods(REGISTRY)


def handle_message(workspace: Workspace, message: bytes) -> bytes | None:
    """One framed request in, one framed reply out -- or None for a
    notification, which by JSON-RPC is answered with silence.

    A DAEMON ANSWERS, IT DOES NOT DIE. pjrpc already turns a method that
    raises into an error response; this catches the narrow band outside that
    -- a result its encoder cannot serialize, say -- which would otherwise
    reach socketserver as an unhandled exception and drop the connection with
    the caller still waiting on a line.
    """
    try:
        dispatched = DISPATCHER.dispatch(message.decode("utf-8", errors="replace"), workspace)
    except Exception as exc:  # noqa: BLE001 -- see the docstring
        response = Response(id=None, error=rpc_exceptions.InternalError(data=str(exc)))
        return (json.dumps(response.to_json(), separators=(",", ":")) + "\n").encode("utf-8")
    if dispatched is None:
        return None
    response_text, _codes = dispatched
    return (response_text + "\n").encode("utf-8")


def _too_large_reply() -> bytes:
    response = Response(
        id=None,
        error=rpc_exceptions.InvalidRequestError(
            data=f"request exceeds {MAX_REQUEST_BYTES} bytes",
        ),
    )
    return (json.dumps(response.to_json(), separators=(",", ":")) + "\n").encode("utf-8")


class RpcHandler(socketserver.StreamRequestHandler):
    server: "RpcServer"

    def handle(self) -> None:
        while message := self.rfile.readline(MAX_REQUEST_BYTES + 1):
            if len(message) > MAX_REQUEST_BYTES:
                self._discard_rest_of_line()
                self.wfile.write(_too_large_reply())
                return
            reply = handle_message(self.server.workspace, message)
            if reply is not None:
                self.wfile.write(reply)

    def _discard_rest_of_line(self) -> None:
        """Read the tail of an oversized request so the refusal can be
        DELIVERED. Closing on a client that is still writing costs it the
        message and hands it an EPIPE instead."""
        discarded = 0
        while discarded < MAX_DISCARD_BYTES:
            chunk = self.rfile.readline(min(65536, MAX_DISCARD_BYTES - discarded) + 1)
            if not chunk:
                return
            discarded += len(chunk)
            if chunk.endswith(b"\n"):
                return


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
