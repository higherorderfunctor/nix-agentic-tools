#!/usr/bin/env python3
# cspell:ignore sdoc sockaddr unrelate
"""Contracts for the scribe socket, its client, and the export
(MECH-SCRIBE-RPC, MECH-SCRIBE-SOCKET-IDENTITY, MECH-SCRIBE-EXPORT-PAYLOAD).

Every contract runs against a real server on a real socket in a temporary
runtime directory, never the live one, so a running daemon is neither
required nor disturbed.

    python3 dev/scripts/test_scribe_rpc.py
"""

from __future__ import annotations

import json
import os
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
from contextlib import contextmanager, redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent))

from scribe_client import ClientError, NoDaemon, call, call_for_root  # noqa: E402
from scribe_contract import WorkspaceGrammarResult  # noqa: E402
import scribe_cmd  # noqa: E402
from scribe_grammar import parse_sgra  # noqa: E402
import scribe_paths  # noqa: E402
from scribe_rpc import MAX_REQUEST_BYTES, SCHEMA, build_server  # noqa: E402
from scribe_workspace import Workspace  # noqa: E402
from sdoc_model import authoring_elements  # noqa: E402

# One tracked-tree corpus fixture, shared with the workspace suite. This file
# proves the copy can go through a separate `strictdoc export` process rather
# than relying on the test interpreter's imports; see `corpus` for why File
# targets and symlinks require the complete tracked shape.
from test_scribe_workspace import corpus  # noqa: E402

PASSED: list[str] = []


@contextmanager
def served(root: Path, runtime: Path):
    """A live server on its own socket, torn down on the way out."""
    os.environ["XDG_RUNTIME_DIR"] = str(runtime)
    path = scribe_paths.socket_path(root)
    workspace = Workspace(root)
    workspace.current()
    server = build_server(workspace, path)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield workspace, path
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def contract(name: str):
    def wrap(fn):
        def run(*a):
            started = time.perf_counter()
            fn(*a)
            PASSED.append(name)
            print(f"  ok  {name}  ({(time.perf_counter() - started) * 1000:.1f} ms)")
        run.__name__ = fn.__name__
        return run
    return wrap


@contract("no daemon is a NoDaemon carrying the remedy, not a hang")
def test_fails_closed(root: Path, runtime: Path) -> None:
    os.environ["XDG_RUNTIME_DIR"] = str(runtime)
    try:
        call(scribe_paths.socket_path(root), "daemon.ping")
    except NoDaemon as exc:
        assert "devenv up scribe" in str(exc), "the refusal does not name the remedy"
        return
    raise AssertionError("a missing daemon did not raise NoDaemon")


@contract("the socket is 0600 inside a 0700 directory")
def test_permissions(root: Path, runtime: Path) -> None:
    with served(root, runtime) as (_ws, path):
        assert stat.S_IMODE(path.stat().st_mode) == 0o600, "socket is not 0600"
        assert stat.S_IMODE(path.parent.stat().st_mode) == 0o700, "directory is not 0700"


@contract("a second daemon on one workspace is refused, not silently accepted")
def test_single_owner(root: Path, runtime: Path) -> None:
    with served(root, runtime) as (_ws, path):
        try:
            build_server(Workspace(root), path)
        except RuntimeError as exc:
            assert "already owns" in str(exc)
            return
        raise AssertionError("a second server took over a live socket")


@contract("a dead daemon's leftover socket is replaced")
def test_stale_socket(root: Path, runtime: Path) -> None:
    os.environ["XDG_RUNTIME_DIR"] = str(runtime)
    path = scribe_paths.socket_path(root)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    # A bound-then-abandoned socket file: present, but nothing listening.
    orphan = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    orphan.bind(str(path))
    orphan.close()
    assert path.exists(), "positive control failed: no leftover to replace"
    with served(root, runtime) as (_ws, live):
        assert live.exists()
        assert call(live, "daemon.ping")["ok"] is True


@contract("an unknown method is a JSON-RPC error, and the daemon survives it")
def test_unknown_method(root: Path, runtime: Path) -> None:
    with served(root, runtime) as (_ws, path):
        try:
            call(path, "workspace.detonate")
        except ClientError as exc:
            assert "-32601" in str(exc), f"wrong error for an unknown method: {exc}"
        else:
            raise AssertionError("an unknown method was accepted")
        assert call(path, "daemon.ping")["ok"] is True, "the daemon died on a bad method"


@contract("a daemon serving another workspace is refused, not believed")
def test_root_assertion(root: Path, runtime: Path) -> None:
    with served(root, runtime) as (_ws, path):
        elsewhere = root.parent / "not-this-workspace"
        elsewhere.mkdir(exist_ok=True)
        try:
            call_for_root(elsewhere, "daemon.ping", override=path)
        except ClientError as exc:
            assert "refusing to answer" in str(exc)
            return
        raise AssertionError("the client accepted another workspace's answer")


def _new_argv(tag: str, element: dict) -> list[str]:
    argv = ["new", tag]
    for field in element["fields"]:
        if not field["required"] or field["name"] in scribe_cmd.GUARDED:
            continue
        if field["name"] == "UID":
            value = f"{element['prefix']}CLI-DRY-RUN"
        elif field["options"]:
            value = field["options"][0]
        else:
            value = f"CLI value for {field['name']}"
        argv.extend((scribe_cmd.flag_for(field["name"]), value))
    return [*argv, "--path", "docs/plans/cli-dry-run/", "--dry-run"]


@contract("the client accepts dry-run on every writing parser and sends it once")
def test_cli_dry_run_surface(root: Path, _runtime: Path) -> None:
    grammar = parse_sgra(root / "docs" / "sdoc" / "grammar.sgra")
    commands = {
        "delete": ["delete", "MECH-CLI-DRY-RUN", "--dry-run"],
        "move": ["move", "MECH-CLI-DRY-RUN", "--path", "docs/spec/", "--dry-run"],
        "relate": [
            "relate", "MECH-CLI-DRY-RUN", "--role", "Assumes",
            "--target", "MECH-TARGET", "--dry-run",
        ],
        "set": ["set", "MECH-CLI-DRY-RUN", "--title", "Preview", "--dry-run"],
        "unrelate": [
            "unrelate", "MECH-CLI-DRY-RUN", "--role", "Assumes",
            "--target", "MECH-TARGET", "--dry-run",
        ],
    }
    for command, argv in commands.items():
        parser = scribe_cmd.build_parser(grammar, command, None)
        payload = scribe_cmd.operation(parser.parse_args(argv), grammar)
        assert payload["op"] == command
        assert payload["dry_run"] is True
        real = scribe_cmd.operation(
            parser.parse_args([argument for argument in argv if argument != "--dry-run"]),
            grammar,
        )
        assert real["dry_run"] is False

    for tag, element in grammar.items():
        parser = scribe_cmd.build_parser(grammar, "new", tag)
        argv = _new_argv(tag, element)
        payload = scribe_cmd.operation(parser.parse_args(argv), grammar)
        assert payload["op"] == "new"
        assert payload["type"] == tag
        assert payload["dry_run"] is True
        real = scribe_cmd.operation(
            parser.parse_args([argument for argument in argv if argument != "--dry-run"]),
            grammar,
        )
        assert real["dry_run"] is False


@contract("help gets all eight types and per-type flags from the daemon")
def test_cli_help_from_daemon(root: Path, runtime: Path) -> None:
    with served(root, runtime):
        outputs = []
        for argv in (
            ["--root", str(root), "new", "--help"],
            ["--root", str(root), "new", "WORK", "--help"],
        ):
            stdout = StringIO()
            with redirect_stdout(stdout):
                assert scribe_cmd.main(argv) == 0
            outputs.append(stdout.getvalue())
        type_help, work_help = outputs
        for tag in (
            "COMMENTARY",
            "DECISION",
            "EVIDENCE",
            "MECHANISM",
            "NARRATIVE",
            "REQUIREMENT",
            "USE_CASE",
            "WORK",
        ):
            assert tag in type_help, f"new help omitted {tag}: {type_help}"
        for flag in ("--uid", "--title", "--statement", "--comment", "--relate"):
            assert flag in work_help, f"WORK help omitted {flag}: {work_help}"
        assert "--authored-by" not in work_help


@contract("help without a daemon prints the unchanged remedy and boot usage")
def test_cli_help_without_daemon(root: Path, runtime: Path) -> None:
    os.environ["XDG_RUNTIME_DIR"] = str(runtime)
    stderr = StringIO()
    with redirect_stderr(stderr):
        assert scribe_cmd.main(["--root", str(root), "--help"]) == 1
    path = scribe_paths.socket_path(root)
    assert stderr.getvalue() == (
        f"scribe: no scribe daemon on {path}.\n"
        "  start one with:  devenv up scribe\n"
        "  or directly:     scribe-daemon --root <worktree>\n"
        "usage: scribe [--root ROOT]\n"
    )


@contract("a guarded flag is refused before any socket connect")
def test_cli_guard_precedes_connect(root: Path, _runtime: Path) -> None:
    attempted = []
    original = socket.socket.connect

    def unexpected_connect(connection, address):
        attempted.append(address)
        raise AssertionError(f"guarded argv reached socket connect: {address}")

    socket.socket.connect = unexpected_connect
    try:
        stderr = StringIO()
        with redirect_stderr(stderr):
            code = scribe_cmd.main(
                ["--root", str(root), "new", "WORK", "--authored-by", "human"]
            )
    finally:
        socket.socket.connect = original
    assert code == 1
    assert "AUTHORED_BY is the operator's to set" in stderr.getvalue()
    assert attempted == []


@contract("a socket dry-run returns its diff and leaves disk and reads unchanged")
def test_rpc_dry_run(root: Path, runtime: Path) -> None:
    with served(root, runtime) as (_workspace, path):
        uid = next(
            node.reserved_uid
            for node in _workspace.graph.iter_nodes()
            if node.reserved_uid and getattr(node, "reserved_title", None)
        )
        source = _workspace.graph.path_of(_workspace.graph.node(uid))
        before_read = call(path, "scribe.apply", {"op": "show", "uid": uid})
        before_bytes = source.read_bytes()
        before_mtime = source.stat().st_mtime_ns
        params = {
            "op": "set",
            "uid": uid,
            "fields": {"TITLE": "RPC dry-run contract title"},
            "unset": [],
        }
        preview = call(path, "scribe.apply", {**params, "dry_run": True})
        assert "+TITLE: RPC dry-run contract title" in preview["text"]
        assert preview["written"] == []
        assert source.read_bytes() == before_bytes
        assert source.stat().st_mtime_ns == before_mtime
        assert call(path, "scribe.apply", {"op": "show", "uid": uid}) == before_read

        # POSITIVE CONTROL: the identical RPC without dry-run writes.
        written = call(path, "scribe.apply", params)
        assert written["written"] == [str(source.relative_to(root))]
        assert source.read_bytes() != before_bytes
        assert source.stat().st_mtime_ns != before_mtime


@contract("workspace generations stay monotonic across real and dry-run writes")
def test_rpc_dry_run_generation(root: Path, runtime: Path) -> None:
    with served(root, runtime) as (workspace, path):
        uid = next(
            node.reserved_uid
            for node in workspace.graph.iter_nodes()
            if node.reserved_uid and getattr(node, "reserved_title", None)
        )
        generations = [call(path, "workspace.describe")["generation"]]
        for title in ("First real generation", "Second real generation"):
            call(
                path,
                "scribe.apply",
                {
                    "op": "set",
                    "uid": uid,
                    "fields": {"TITLE": title},
                    "unset": [],
                },
            )
            generations.append(call(path, "workspace.describe")["generation"])

        call(
            path,
            "scribe.apply",
            {
                "op": "set",
                "uid": uid,
                "fields": {"TITLE": "Dry-run generation"},
                "unset": [],
                "dry_run": True,
            },
        )
        generations.append(call(path, "workspace.describe")["generation"])

        assert all(
            before < after for before, after in zip(generations, generations[1:])
        ), f"generation did not increase monotonically: {generations}"


@contract("dry-run and real CLI refusals have the same message and exit code")
def test_cli_dry_run_refusal(root: Path, runtime: Path) -> None:
    with served(root, runtime) as (workspace, _path):
        uid = next(
            node.reserved_uid
            for node in workspace.graph.iter_nodes()
            if node.reserved_uid and getattr(node, "reserved_title", None)
        )
        source = workspace.graph.path_of(workspace.graph.node(uid))
        original = source.read_bytes()
        outcomes = []
        base = [
            "--root", str(root), "set", uid, "--statement",
            "Points at [LINK: NO-SUCH-CLI-DRY-RUN-UID].",
        ]
        for argv in ([*base, "--dry-run"], base):
            stdout = StringIO()
            stderr = StringIO()
            with redirect_stdout(stdout), redirect_stderr(stderr):
                code = scribe_cmd.main(argv)
            outcomes.append((code, stdout.getvalue(), stderr.getvalue()))
            assert source.read_bytes() == original, "a refused CLI operation changed bytes"
        assert outcomes[0] == outcomes[1]
        assert outcomes[0][0] == 1
        assert "NO-SUCH-CLI-DRY-RUN-UID" in outcomes[0][2]


def _without_daemon_additions(index: dict) -> tuple[dict, int, int]:
    """The export as strictdoc's own CLI would write it, and how many of each
    daemon-only addition were dropped to get there: element-grained File item
    slots, and every node's declaring `_DOCUMENT_PATH`."""
    slots = 0
    paths = 0
    for document in index.get("DOCUMENTS", []):
        for node in document.get("NODES", []):
            if node.pop("_DOCUMENT_PATH", None) is not None:
                paths += 1
            for relation in node.get("RELATIONS", []) or []:
                if relation.get("TYPE") != "File":
                    continue
                for slot in ("ELEMENT", "ID"):
                    if relation.pop(slot, None) is not None:
                        slots += 1
    return index, slots, paths


@contract("the daemon's export is strictdoc's own, plus the item slots and node paths")
def test_export_matches(root: Path, runtime: Path) -> None:
    """It used to be byte-identical, and it is still identical everywhere the
    two can agree.

    Two deliberate differences. ELEMENT and ID on a File relation: strictdoc's
    JSON generator reads neither off a FileReference, so an element-grained
    relation would export as a whole-file one and the board would draw a
    coarser graph than the corpus declares. And `_DOCUMENT_PATH`: the
    generator receives each node's declaring document but omits its path, so
    a consumer would have to walk the corpus a second time to recover it.
    sdoc_model wraps one generator method for each -- see
    carry_file_element_into_json and carry_document_path_into_json -- and
    `strictdoc export` run BY HAND still writes neither, which is the accepted
    cost of leaving the packaged strictdoc untouched.

    So the comparison normalizes both differences away and then asserts they
    were real: strip them and the two exports must be equal, and every node
    must have had a path to strip.
    """
    import json

    with served(root, runtime) as (_ws, path):
        mine = root / "out-daemon"
        result = call(path, "workspace.export", {"outputDir": str(mine)})
        assert result["bytes"] > 0

    theirs = root / "out-cli"
    strictdoc = shutil.which("strictdoc")
    assert strictdoc, "strictdoc is not on PATH; cannot run the comparison"
    environment = {k: v for k, v in os.environ.items() if k not in ("PYTHONPATH", "STRICTDOC_CACHE_DIR")}
    subprocess.run(
        [strictdoc, "export", ".", "--formats=json", "--output-dir", str(theirs)],
        cwd=root, check=True, capture_output=True, env=environment,
    )
    a = (mine / "json" / "index.json").read_bytes()
    b = (theirs / "json" / "index.json").read_bytes()
    normalized, slots, paths = _without_daemon_additions(json.loads(a))
    # A positive control on the path patch: every exported node carries one,
    # so zero means the patch did not fire rather than that the corpus is
    # unusual. The item slots are optional -- a corpus may name no items.
    assert paths, (
        f"the daemon export carried no _DOCUMENT_PATH at all: "
        f"{len(a)} vs {len(b)} bytes"
    )
    assert normalized == json.loads(b), (
        f"exports differ beyond the {paths} document path(s) and "
        f"{slots} File item slot(s) the daemon adds"
    )

# ── The twelve gaps WORK-RPC-ON-PJRPC-AND-PYDANTIC closes ────────────────────
#
# Five of them were SILENT: the request was accepted and something wrong
# happened quietly. Each contract below sends the bad payload and asserts the
# refusal names the field, because a refusal that does not name the field
# leaves the caller bisecting its own payload.
#
# The three client-side ones need a daemon that answers WRONG, which a correct
# daemon by definition will not, so they run against `fake_daemon` -- a socket
# that replies with one fixed line.


@contextmanager
def fake_daemon(runtime: Path, reply: bytes):
    """A socket that answers every request with `reply`, verbatim.

    A malformed reply is the one thing the real server cannot produce, and the
    client's handling of it is exactly what is under test.
    """
    runtime.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = runtime / "fake.sock"
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(str(path))
    listener.listen(1)

    def serve() -> None:
        try:
            connection, _ = listener.accept()
        except OSError:
            return
        with connection:
            connection.recv(65536)
            connection.sendall(reply)

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    try:
        yield path
    finally:
        listener.close()
        thread.join(timeout=5)
        path.unlink(missing_ok=True)


def _refusal(path: Path, params: dict) -> str:
    """Send `params` to scribe.apply and return the refusal, or fail loudly."""
    try:
        call(path, "scribe.apply", params)
    except ClientError as exc:
        return str(exc)
    raise AssertionError(f"the daemon accepted {params!r}")


@contract("gap 1: a truthy STRING for dry_run is refused, not treated as true")
def test_dry_run_string_refused(root: Path, runtime: Path) -> None:
    with served(root, runtime) as (workspace, path):
        uid = next(node.reserved_uid for node in workspace.graph.iter_nodes() if node.reserved_uid)
        source = workspace.graph.path_of(workspace.graph.node(uid))
        before = source.read_bytes()
        params = {"op": "set", "uid": uid, "fields": {"TITLE": "String dry-run"}}

        refusal = _refusal(path, {**params, "dry_run": "false"})
        assert "-32602" in refusal, refusal
        assert "dry_run" in refusal, f"the refusal does not name the field: {refusal}"
        assert source.read_bytes() == before, "a string dry_run reached the disk"

        # POSITIVE CONTROL: the same payload with a real bool is accepted, so
        # the refusal above is about the TYPE and not about the operation.
        assert call(path, "scribe.apply", {**params, "dry_run": True})["written"] == []


@contract("gap 2: a key another operation declares is refused on THIS one")
def test_unknown_param_key_refused(root: Path, runtime: Path) -> None:
    with served(root, runtime) as (workspace, path):
        uid = next(node.reserved_uid for node in workspace.graph.iter_nodes() if node.reserved_uid)
        # `role` is real -- `relate` takes it -- and meaningless on a `set`.
        # It used to be dropped, so the caller was told nothing.
        refusal = _refusal(
            path,
            {"op": "set", "uid": uid, "fields": {"TITLE": "Stray role"}, "role": "Assumes"},
        )
        assert "-32602" in refusal, refusal
        assert "role" in refusal, f"the refusal does not name the field: {refusal}"

        # POSITIVE CONTROL: the same key on the operation that DOES declare it
        # gets PAST parameter validation. What refuses it then is the corpus --
        # a role the node's type does not declare, or a target that is not
        # there -- and either way it is no longer -32602.
        declined = _refusal(
            path, {"op": "relate", "uid": uid, "role": "Assumes", "target": "NO-SUCH-UID"}
        )
        assert "-32602" not in declined, f"role was refused on relate too: {declined}"


@contract("gap 3: fields as a list of pairs is refused, not silently ignored")
def test_fields_list_of_pairs_refused(root: Path, runtime: Path) -> None:
    with served(root, runtime) as (workspace, path):
        uid = next(node.reserved_uid for node in workspace.graph.iter_nodes() if node.reserved_uid)
        refusal = _refusal(path, {"op": "set", "uid": uid, "fields": [["TITLE", "Pairs"]]})
        assert "-32602" in refusal, refusal
        assert "fields" in refusal, f"the refusal does not name the field: {refusal}"


@contract("gap 4: an int where a string was declared is refused, naming the field")
def test_uid_int_refused_naming_field(root: Path, runtime: Path) -> None:
    with served(root, runtime) as (_ws, path):
        refusal = _refusal(path, {"op": "show", "uid": 7})
        assert "-32602" in refusal, refusal
        assert "uid" in refusal, f"the refusal does not name the field: {refusal}"
        assert "string" in refusal.lower(), refusal


@contract("gap 5: the served-root check RUNS on a non-dict result")
def test_root_check_runs_on_non_dict_result(root: Path, runtime: Path) -> None:
    """It used to be skipped: `result.get("root") if isinstance(result, dict)`
    made a bare string or list pass the one assertion standing between a
    misdirected socket and another worktree's canon."""
    reply = json.dumps({"jsonrpc": "2.0", "id": 1, "result": "not an object"}) + "\n"
    with fake_daemon(runtime / "fake", reply.encode("utf8")) as path:
        try:
            call_for_root(root, "daemon.ping", override=path)
        except ClientError as exc:
            assert "not an object" in str(exc) or "not an object" in repr(exc), exc
            assert "str" in str(exc), f"the refusal does not name the shape: {exc}"
            return
        raise AssertionError("a non-dict result skipped the served-root check")


@contract("gap 6: a reply with neither result nor error is a ClientError")
def test_client_refuses_missing_result(root: Path, runtime: Path) -> None:
    reply = json.dumps({"jsonrpc": "2.0", "id": 1}) + "\n"
    with fake_daemon(runtime / "fake", reply.encode("utf8")) as path:
        try:
            call(path, "daemon.ping")
        except ClientError as exc:
            assert "neither a result nor an error" in str(exc), exc
            return
        raise AssertionError("a reply with no result was accepted")


@contract("gap 7: an error that is not an object is a ClientError")
def test_client_refuses_malformed_error(root: Path, runtime: Path) -> None:
    reply = json.dumps({"jsonrpc": "2.0", "id": 1, "error": "boom"}) + "\n"
    with fake_daemon(runtime / "fake", reply.encode("utf8")) as path:
        try:
            call(path, "daemon.ping")
        except ClientError as exc:
            assert "not a JSON-RPC response" in str(exc), exc
            assert "error" in str(exc), f"the refusal does not name the field: {exc}"
            return
        raise AssertionError("a non-object error was indexed rather than refused")


@contract("gap 8: a reply that is not JSON is a ClientError, not a traceback")
def test_client_refuses_non_json_line(root: Path, runtime: Path) -> None:
    with fake_daemon(runtime / "fake", b"this is not json\n") as path:
        try:
            call(path, "daemon.ping")
        except ClientError as exc:
            assert "not JSON" in str(exc), exc
            return
        raise AssertionError("a non-JSON line reached json.loads unguarded")


@contract("gap 9: a request id of the wrong type is refused, naming id")
def test_id_type_checked_or_documented(root: Path, runtime: Path) -> None:
    with served(root, runtime) as (_ws, path):
        try:
            call(path, "daemon.ping", request_id={"not": "an id"})
        except ClientError as exc:
            assert "-32600" in str(exc), exc
            assert "id" in str(exc), f"the refusal does not name the field: {exc}"
        else:
            raise AssertionError("an object id was accepted")

        # POSITIVE CONTROL: a string id, which JSON-RPC 2.0 does allow.
        assert call(path, "daemon.ping", request_id="an-id")["ok"] is True


@contract("gap 10: a relations entry that is not an object is refused by index")
def test_relations_non_dict_entry_refused(root: Path, runtime: Path) -> None:
    with served(root, runtime) as (_ws, path):
        refusal = _refusal(
            path,
            {
                "op": "new", "type": "WORK", "uid": "WORK-RELATIONS-CONTRACT",
                "path": "docs/plans/relations-contract/", "relations": ["Assumes=X"],
            },
        )
        assert "-32602" in refusal, refusal
        assert "relations" in refusal, f"the refusal does not name the field: {refusal}"
        assert "0" in refusal, f"the refusal does not name the entry: {refusal}"


@contract("gap 11: an oversized request is refused cleanly, and the daemon lives")
def test_oversized_request_refused_cleanly(root: Path, runtime: Path) -> None:
    with served(root, runtime) as (_ws, path):
        try:
            call(path, "scribe.apply", {"op": "show", "uid": "X" * (MAX_REQUEST_BYTES + 4096)})
        except ClientError as exc:
            assert "-32600" in str(exc), exc
            assert str(MAX_REQUEST_BYTES) in str(exc), f"the refusal does not name the cap: {exc}"
        else:
            raise AssertionError("a request over the cap was accepted")
        assert call(path, "daemon.ping")["ok"] is True, "the daemon died on an oversized request"


@contract("gap 12: an unknown key on scribe.apply is refused, naming the key")
def test_extra_key_on_scribe_apply_refused(root: Path, runtime: Path) -> None:
    with served(root, runtime) as (_ws, path):
        refusal = _refusal(path, {"op": "check", "verbosity": "loud"})
        assert "-32602" in refusal, refusal
        assert "verbosity" in refusal, f"the refusal does not name the key: {refusal}"

        # POSITIVE CONTROL: without the stray key the identical call answers.
        assert "text" in call(path, "scribe.apply", {"op": "check"})


@contract("an understood workspace refusal from scribe.apply remains -32002")
def test_apply_workspace_error_is_refused(root: Path, runtime: Path) -> None:
    with served(root, runtime) as (_ws, path):
        refusal = _refusal(
            path,
            {
                "op": "relate",
                "uid": "REQ-DAEMON-IS-THE-ONLY-SOURCE",
                "role": "Crosses",
                "target": "MECH-SCRIBE-RPC",
                "line_range": "1-2",
                "dry_run": True,
            },
        )
        assert "-32002 Refused" in refusal, refusal
        assert "may not make a 'Crosses' relation" in refusal, refusal


@contract("an unexpected method exception is -32603 with diagnostic data")
def test_method_exception_keeps_diagnostic(root: Path, runtime: Path) -> None:
    with served(root, runtime) as (_ws, path):
        try:
            call(path, "workspace.export", {"outputDir": "/dev/null/x"})
        except ClientError as exc:
            refusal = str(exc)
            assert "-32603 Internal error" in refusal, refusal
            assert "Not a directory" in refusal, refusal
            assert "/dev/null/x/json" in refusal, refusal
        else:
            raise AssertionError("an impossible export path was accepted")


@contract("top-level lineRange remains an alias for line_range")
def test_top_level_line_range_alias(root: Path, runtime: Path) -> None:
    with served(root, runtime) as (_ws, path):
        base = {
            "op": "relate",
            "uid": "REQ-DAEMON-IS-THE-ONLY-SOURCE",
            "role": "Crosses",
            "target": "MECH-SCRIBE-RPC",
            "dry_run": True,
        }
        aliased = _refusal(path, {**base, "lineRange": "1-2"})
        canonical = _refusal(path, {**base, "line_range": "1-2"})
        assert "-32602" not in aliased, aliased
        assert "-32002 Refused" in aliased, aliased
        assert aliased == canonical, (aliased, canonical)


@contract("rpc.discover reports schema 2 and the methods the registry holds")
def test_discover_reports_the_registry(root: Path, runtime: Path) -> None:
    with served(root, runtime) as (_ws, path):
        discovered = call(path, "rpc.discover")
        assert discovered["schema"] == SCHEMA == "scribe-rpc/2", discovered
        assert discovered["framing"] == "one-json-value-per-newline"
        for method in discovered["methods"]:
            # Every advertised method answers something other than -32601.
            try:
                call(path, method)
            except ClientError as exc:
                assert "-32601" not in str(exc), f"{method} is advertised and absent: {exc}"


@contract("workspace.grammar round-trips all eight author-facing types")
def test_workspace_grammar(root: Path, runtime: Path) -> None:
    with served(root, runtime) as (workspace, path):
        result = call(path, "workspace.grammar")
        parsed = WorkspaceGrammarResult.model_validate(result)
        assert json.loads(parsed.model_dump_json(by_alias=True)) == result
        assert set(result) == {"schema", "types"}
        assert result["schema"] == "scribe-grammar/1"
        assert set(result["types"]) == {
            "COMMENTARY",
            "DECISION",
            "EVIDENCE",
            "MECHANISM",
            "NARRATIVE",
            "REQUIREMENT",
            "USE_CASE",
            "WORK",
        }
        assert "TEXT" in workspace.graph.grammar.elements_by_type
        assert "TEXT" not in result["types"]
        assert result["types"]["WORK"]["fields"][0] == {
            "name": "UID",
            "kind": "String",
            "required": True,
            "options": [],
        }
        assert {role["role"] or role["type"] for role in result["types"]["WORK"]["roles"]} >= {
            "Assumes",
            "File",
        }


@contract("the author-facing grammar filter removes even a declared TEXT")
def test_workspace_grammar_declared_text_positive_control(
    _root: Path, _runtime: Path
) -> None:
    grammar = SimpleNamespace(elements_by_type={"TEXT": object(), "WORK": object()})
    assert "TEXT" in grammar.elements_by_type, "positive control did not declare TEXT"
    assert list(authoring_elements(grammar)) == ["WORK"]


CONTRACTS = [
    test_fails_closed,
    test_permissions,
    test_single_owner,
    test_stale_socket,
    test_unknown_method,
    test_root_assertion,
    test_cli_dry_run_surface,
    test_cli_help_from_daemon,
    test_cli_help_without_daemon,
    test_cli_guard_precedes_connect,
    test_rpc_dry_run,
    test_rpc_dry_run_generation,
    test_cli_dry_run_refusal,
    test_export_matches,
    test_discover_reports_the_registry,
    test_dry_run_string_refused,
    test_unknown_param_key_refused,
    test_fields_list_of_pairs_refused,
    test_uid_int_refused_naming_field,
    test_root_check_runs_on_non_dict_result,
    test_client_refuses_missing_result,
    test_client_refuses_malformed_error,
    test_client_refuses_non_json_line,
    test_id_type_checked_or_documented,
    test_relations_non_dict_entry_refused,
    test_oversized_request_refused_cleanly,
    test_extra_key_on_scribe_apply_refused,
    test_apply_workspace_error_is_refused,
    test_method_exception_keeps_diagnostic,
    test_top_level_line_range_alias,
    test_workspace_grammar,
    test_workspace_grammar_declared_text_positive_control,
]


def main() -> int:
    failures = 0
    for fn in CONTRACTS:
        with tempfile.TemporaryDirectory(prefix="scribe-rpc-") as tmp:
            base = Path(tmp)
            runtime = base / "run"
            runtime.mkdir(mode=0o700)
            root = corpus(base / "corpus")
            try:
                fn(root, runtime)
            except Exception as exc:  # noqa: BLE001 -- report all, exit non-zero after
                failures += 1
                print(f"  FAIL  {fn.__name__}: {type(exc).__name__}: {exc}")
    print(f"\n{len(PASSED)} passed, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
