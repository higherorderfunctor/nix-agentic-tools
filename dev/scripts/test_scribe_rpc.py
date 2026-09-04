#!/usr/bin/env python3
# cspell:ignore sdoc sockaddr unrelate
"""Contracts for the scribe socket, its client, and the export
(WORK-SCRIBE-RPC-AND-SERVICE, WORK-SCRIBE-CLIENT, WORK-SCRIBE-EXPORT-PAYLOAD).

Every contract runs against a real server on a real socket in a temporary
runtime directory, never the live one, so a running daemon is neither
required nor disturbed.

    python3 dev/scripts/test_scribe_rpc.py
"""

from __future__ import annotations

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

sys.path.insert(0, str(Path(__file__).resolve().parent))

from scribe_client import ClientError, NoDaemon, call, call_for_root  # noqa: E402
import scribe_cmd  # noqa: E402
from scribe_grammar import parse_sgra  # noqa: E402
import scribe_paths  # noqa: E402
from scribe_rpc import build_server  # noqa: E402
from scribe_workspace import Workspace  # noqa: E402

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


@contract("the client imports and prints help with only the standard library")
def test_cli_stdlib_only(root: Path, _runtime: Path) -> None:
    script_dir = root / "dev" / "scripts"
    code = (
        "import sys; "
        f"sys.path.insert(0, {str(script_dir)!r}); "
        "import scribe_cmd; "
        "raise SystemExit(scribe_cmd.main("
        f"['--root', {str(root)!r}, '--help']))"
    )
    environment = {
        key: value
        for key, value in os.environ.items()
        if key not in ("PYTHONHOME", "PYTHONPATH")
    }
    result = subprocess.run(
        [sys.executable, "-I", "-S", "-c", code],
        capture_output=True,
        text=True,
        env=environment,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout.startswith("usage: scribe "), result.stdout


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


def _without_item_slots(index: dict) -> tuple[dict, int]:
    """The export as strictdoc's own CLI would write it, and how many item
    slots were dropped to get there."""
    dropped = 0
    for document in index.get("DOCUMENTS", []):
        for node in document.get("NODES", []):
            for relation in node.get("RELATIONS", []) or []:
                if relation.get("TYPE") != "File":
                    continue
                for slot in ("ELEMENT", "ID"):
                    if relation.pop(slot, None) is not None:
                        dropped += 1
    return index, dropped


@contract("the daemon's export is strictdoc's own, plus the File item slots")
def test_export_matches(root: Path, runtime: Path) -> None:
    """It used to be byte-identical, and it is still identical everywhere the
    two can agree.

    The one deliberate difference is ELEMENT and ID on a File relation:
    strictdoc's JSON generator reads neither off a FileReference, so an
    element-grained relation would export as a whole-file one and the board
    would draw a coarser graph than the corpus declares. sdoc_model wraps
    that one method for exports taken through this repo -- see
    carry_file_element_into_json -- and `strictdoc export` run BY HAND still
    drops the slots, which is the accepted cost of leaving the packaged
    strictdoc untouched.

    So the comparison normalizes the difference away and then asserts the
    difference was real: strip the slots and the two exports must be equal,
    and a corpus that carries any must have had some to strip.
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
    if a == b:
        # Nothing in this corpus names an item, so there is nothing to
        # normalize and byte equality is the whole contract.
        return
    normalized, dropped = _without_item_slots(json.loads(a))
    assert dropped, (
        f"exports differ by something other than the File item slots: "
        f"{len(a)} vs {len(b)} bytes"
    )
    assert normalized == json.loads(b), (
        f"exports differ beyond the {dropped} File item slot(s) the daemon adds"
    )


CONTRACTS = [
    test_fails_closed,
    test_permissions,
    test_single_owner,
    test_stale_socket,
    test_unknown_method,
    test_root_assertion,
    test_cli_dry_run_surface,
    test_cli_stdlib_only,
    test_rpc_dry_run,
    test_rpc_dry_run_generation,
    test_cli_dry_run_refusal,
    test_export_matches,
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
