#!/usr/bin/env python3
# cspell:ignore sdoc sockaddr
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
from contextlib import contextmanager
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import scribe_paths  # noqa: E402
from scribe_client import ClientError, NoDaemon, call, call_for_root  # noqa: E402
from scribe_rpc import build_server  # noqa: E402
from scribe_workspace import Workspace  # noqa: E402

# One definition of an exportable corpus copy, shared with the workspace
# suite. See CORPUS_PATHS there for what it must carry and why -- in
# particular, this file is the only place a corpus that omits dev/scripts
# fails, because it is the only one that shells out to `strictdoc export`.
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
