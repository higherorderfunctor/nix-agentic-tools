#!/usr/bin/env python3
# cspell:ignore uids sdoc precheck
"""Contracts for scribe_workspace (WORK-SCRIBE-WORKSPACE).

Runs against an ISOLATED COPY of the canon, never the working tree: every
contract writes, and several deliberately break a document to prove a check
fires. Copying is also what makes the failure assertions mean anything -- a
refusal that left the real corpus alone would be indistinguishable from one
that did nothing.

Each negative contract carries its POSITIVE CONTROL: before asserting a
defect is caught, the same harness is shown accepting the sound version.

    python3 dev/scripts/test_scribe_workspace.py
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from scribe_workspace import (  # noqa: E402
    Workspace,
    WorkspaceError,
    refuse_dangling_links,
    refuse_if_referenced,
)
from sdoc_model import field_value  # noqa: E402

PASSED: list[str] = []


def contract(name: str):
    def wrap(fn):
        def run(root: Path):
            started = time.perf_counter()
            fn(root)
            PASSED.append(name)
            print(f"  ok  {name}  ({(time.perf_counter() - started) * 1000:.0f} ms)")
        run.__name__ = fn.__name__
        return run
    return wrap


def corpus(destination: Path) -> Path:
    repo = Path(__file__).resolve().parents[2]
    listed = subprocess.run(
        ["git", "ls-files", "-z", "*.sdoc", "*.sgra", "strictdoc_config.py"],
        cwd=repo, capture_output=True, text=True, check=True,
    ).stdout.split("\0")
    for name in filter(None, listed):
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(repo / name, target)
    assert (destination / "strictdoc_config.py").is_file()
    return destination


def any_node(workspace: Workspace) -> str:
    for node in workspace.graph.iter_nodes():
        if node.reserved_uid and field_value(node, "TITLE"):
            return node.reserved_uid
    raise AssertionError("corpus copy has no usable node")


def inline_linked_node(workspace: Workspace):
    """A node something points at with [LINK:] -- the class the cheap
    rebuild used to accept deleting."""
    index = workspace.graph.index
    for node in workspace.graph.iter_nodes():
        if not node.reserved_uid:
            continue
        try:
            if index.get_incoming_links(node):
                return node.reserved_uid
        except Exception:
            continue
    return None


# ---- contracts ---------------------------------------------------------


@contract("a repeated read does not reload")
def test_read_is_free(root: Path) -> None:
    workspace = Workspace(root)
    first, second = workspace.current(), workspace.current()
    assert first is second, "the second read rebuilt instead of reusing the generation"
    assert first.number == 1


@contract("a write defers its reload; the next read pays it once")
def test_write_defers(root: Path) -> None:
    workspace = Workspace(root)
    uid = any_node(workspace)
    before = workspace.current()
    workspace.write(lambda g: g.set_field(uid, "TITLE", "Retitled by a contract"))
    assert workspace._dirty, "the write did not mark the graph dirty"
    assert workspace._generation is before, "the write reloaded instead of deferring"
    after = workspace.current()
    assert after.number == before.number + 1
    assert field_value(after.graph.node(uid), "TITLE") == "Retitled by a contract"


@contract("a batch of writes pays ONE reload, not one each")
def test_batch_pays_once(root: Path) -> None:
    workspace = Workspace(root)
    uids = []
    for node in workspace.graph.iter_nodes():
        if node.reserved_uid and field_value(node, "TITLE"):
            uids.append(node.reserved_uid)
        if len(uids) == 5:
            break
    start = workspace.current().number
    for n, uid in enumerate(uids):
        workspace.write(lambda g, u=uid, i=n: g.set_field(u, "TITLE", f"Batched {i}"))
    assert workspace._generation.number == start, "a write inside the batch reloaded"
    workspace.current()
    assert workspace._generation.number == start + 1, "the batch cost more than one reload"


@contract("a refused write never touches the disk")
def test_refusal_moves_nothing(root: Path) -> None:
    workspace = Workspace(root)
    uid = any_node(workspace)
    path = workspace.graph.path_of(workspace.graph.node(uid))
    original = path.read_bytes()
    mtime = path.stat().st_mtime_ns

    def refuse(_graph):
        raise WorkspaceError("refused by the contract")

    try:
        workspace.write(lambda g: g.set_field(uid, "TITLE", "should never land"), precheck=refuse)
    except WorkspaceError:
        pass
    else:
        raise AssertionError("a refused write was accepted")

    assert path.read_bytes() == original, "bytes changed on a refused write"
    assert path.stat().st_mtime_ns == mtime, "the file was rewritten on a refused write"


@contract("a document that would not parse back is refused before the write")
def test_unparseable_refused(root: Path) -> None:
    workspace = Workspace(root)
    uid = any_node(workspace)
    path = workspace.graph.path_of(workspace.graph.node(uid))
    original = path.read_bytes()

    # POSITIVE CONTROL: a sound edit to the same field is accepted.
    workspace.write(lambda g: g.set_field(uid, "STATEMENT", "A perfectly ordinary statement."))
    assert path.read_bytes() != original

    def poison(graph):
        graph.node(uid).set_field_value(
            field_name="STATEMENT", form_field_index=0, value="broken\n<<<\nTITLE: x\n"
        )
        graph._touch(graph.node(uid).get_document())

    good = path.read_bytes()
    try:
        workspace.write(poison)
    except WorkspaceError:
        pass
    else:
        raise AssertionError("an unparseable document was written")
    assert path.read_bytes() == good, "the poisoned render reached the disk"


@contract("a bogus [LINK:] is refused -- the class the cheap rebuild accepted")
def test_dangling_link_refused(root: Path) -> None:
    workspace = Workspace(root)
    uid = any_node(workspace)

    # POSITIVE CONTROL: a link to a node that DOES exist passes the same check.
    other = next(n.reserved_uid for n in workspace.graph.iter_nodes()
                 if n.reserved_uid and n.reserved_uid != uid)
    workspace.write(
        lambda g: g.set_field(uid, "STATEMENT", f"Points at [LINK: {other}] which exists."),
        precheck=refuse_dangling_links,
    )

    try:
        workspace.write(
            lambda g: g.set_field(uid, "STATEMENT", "Points at [LINK: NO-SUCH-UID-ANYWHERE]."),
            precheck=refuse_dangling_links,
        )
    except WorkspaceError as exc:
        assert "NO-SUCH-UID-ANYWHERE" in str(exc)
        return
    raise AssertionError("a dangling inline link was written")


@contract("deleting a node something links to is refused, not undone")
def test_referenced_delete_refused(root: Path) -> None:
    workspace = Workspace(root)
    uid = inline_linked_node(workspace)
    if uid is None:
        print("      (skipped: the corpus copy has no inline-linked node)")
        return
    path = workspace.graph.path_of(workspace.graph.node(uid))
    assert path.exists()
    try:
        workspace.write(lambda g: g.remove_node(uid), precheck=refuse_if_referenced(uid))
    except WorkspaceError:
        assert path.exists(), "the file was deleted despite the refusal"
        return
    raise AssertionError("deleting a referenced node was accepted")


@contract("an edit made outside the workspace is noticed, not overwritten")
def test_external_change_detected(root: Path) -> None:
    workspace = Workspace(root)
    uid = any_node(workspace)
    first = workspace.current()
    path = workspace.graph.path_of(workspace.graph.node(uid))

    # The SECOND "TITLE:" is the node's -- the first belongs to the
    # [DOCUMENT] header, and editing that proves nothing about the node.
    text = path.read_text(encoding="utf8")
    head, marker, tail = text.partition("TITLE: ")
    assert marker and "TITLE: " in tail, "positive control failed: no node title to edit"
    edited = head + marker + tail.replace("TITLE: ", "TITLE: EXTERNALLY ", 1)
    assert edited != text
    path.write_text(edited, encoding="utf8")

    after = workspace.current()
    assert after.number > first.number, "the external edit was not noticed"
    assert "EXTERNALLY" in field_value(after.graph.node(uid), "TITLE")


@contract("a failed reload does not wedge the workspace")
def test_no_wedge(root: Path) -> None:
    workspace = Workspace(root)
    uid = any_node(workspace)
    path = workspace.graph.path_of(workspace.graph.node(uid))
    original = path.read_text(encoding="utf8")

    path.write_text("this is not a document at all\n", encoding="utf8")
    try:
        workspace.current()
    except WorkspaceError:
        pass
    else:
        raise AssertionError("a broken corpus loaded clean")

    # The whole point: repairing the disk must bring it back.
    path.write_text(original, encoding="utf8")
    revived = workspace.current()
    assert revived.graph.has_node(uid), "the workspace stayed wedged after the disk was repaired"


@contract("concurrent writes serialize instead of losing each other")
def test_concurrent_writes(root: Path) -> None:
    workspace = Workspace(root)
    uids = []
    for node in workspace.graph.iter_nodes():
        if node.reserved_uid and field_value(node, "TITLE"):
            uids.append(node.reserved_uid)
        if len(uids) == 2:
            break
    workspace.current()
    barrier = threading.Barrier(2)
    errors: list[BaseException] = []

    def writer(uid: str, label: str):
        try:
            barrier.wait(timeout=30)
            workspace.write(lambda g: g.set_field(uid, "TITLE", label))
        except BaseException as exc:  # noqa: BLE001
            errors.append(exc)

    threads = [
        threading.Thread(target=writer, args=(uids[0], "Writer A")),
        threading.Thread(target=writer, args=(uids[1], "Writer B")),
    ]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=60)

    assert not errors, f"a concurrent write failed: {errors[0]!r}"
    fresh = Workspace(root).current().graph
    assert field_value(fresh.node(uids[0]), "TITLE") == "Writer A", "writer A was lost"
    assert field_value(fresh.node(uids[1]), "TITLE") == "Writer B", "writer B was lost"


CONTRACTS = [
    test_read_is_free,
    test_write_defers,
    test_batch_pays_once,
    test_refusal_moves_nothing,
    test_unparseable_refused,
    test_dangling_link_refused,
    test_referenced_delete_refused,
    test_external_change_detected,
    test_no_wedge,
    test_concurrent_writes,
]


def main() -> int:
    failures = 0
    for fn in CONTRACTS:
        with tempfile.TemporaryDirectory(prefix="scribe-workspace-") as tmp:
            root = corpus(Path(tmp) / "corpus")
            try:
                fn(root)
            except Exception as exc:  # noqa: BLE001 -- report all, exit non-zero after
                failures += 1
                print(f"  FAIL  {fn.__name__}: {type(exc).__name__}: {exc}")
    print(f"\n{len(PASSED)} passed, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
