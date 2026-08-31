#!/usr/bin/env python3
# cspell:ignore uids sdoc
"""Contracts for scribe_workspace (WORK-SCRIBE-WORKSPACE).

Runs against an ISOLATED COPY of the canon, never the working tree: every
contract here writes, and several deliberately corrupt a document to prove a
check fires. Copying is also what makes the failure assertions meaningful --
a rollback that restored the real corpus would be indistinguishable from one
that did nothing.

Each negative contract carries its POSITIVE CONTROL: before asserting that a
defect is caught, the same harness is shown accepting the sound version. A
check that rejects everything passes a negative test for the wrong reason.

    python3 dev/scripts/test_scribe_workspace.py
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from scribe_workspace import Reconcile, Workspace, WorkspaceError  # noqa: E402
from sdoc_model import field_value  # noqa: E402

PASSED: list[str] = []


def contract(name: str):
    def wrap(fn):
        def run(root: Path):
            started = time.perf_counter()
            fn(root)
            ms = (time.perf_counter() - started) * 1000
            PASSED.append(name)
            print(f"  ok  {name}  ({ms:.1f} ms)")

        run.__name__ = fn.__name__
        return run

    return wrap


def corpus(destination: Path) -> Path:
    """An isolated copy of every file strictdoc needs to load this project."""
    repo = Path(__file__).resolve().parents[2]
    listed = subprocess.run(
        ["git", "ls-files", "-z", "*.sdoc", "*.sgra", "strictdoc_config.py"],
        cwd=repo, capture_output=True, text=True, check=True,
    ).stdout.split("\0")
    for name in filter(None, listed):
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(repo / name, target)
    assert (destination / "strictdoc_config.py").is_file(), "corpus copy is missing its config"
    return destination


def some_node(workspace: Workspace) -> str:
    """A UID that exists, chosen from the corpus rather than hard-coded so
    this does not rot when a node is renamed."""
    for node in workspace.graph.iter_nodes():
        uid = node.reserved_uid
        if uid and field_value(node, "TITLE"):
            return uid
    raise AssertionError("corpus copy has no usable node")


# ---- contracts ---------------------------------------------------------


@contract("a repeated read does not reload")
def test_read_is_free(root: Path) -> None:
    workspace = Workspace(root)
    first = workspace.current()
    second = workspace.current()
    assert first is second, "second read rebuilt instead of reusing the generation"
    assert first.graph is second.graph
    assert first.number == 1


@contract("a write defers its rebuild, and the next read pays it once")
def test_write_defers(root: Path) -> None:
    workspace = Workspace(root)
    uid = some_node(workspace)
    before = workspace.current()

    workspace.write(lambda g: g.set_field(uid, "TITLE", "Retitled by a contract"))
    assert workspace._pending is Reconcile.GRAPH, "write did not mark the graph dirty"
    assert workspace._generation is before, "write reconciled eagerly instead of deferring"

    after = workspace.current()
    assert after.number == before.number + 1, "read did not republish a new generation"
    assert workspace._pending is Reconcile.NONE
    assert field_value(after.graph.node(uid), "TITLE") == "Retitled by a contract"


@contract("a batch of writes pays ONE rebuild, not one each")
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
    assert workspace._generation.number == start, "a write in the batch reconciled"
    workspace.current()
    assert workspace._generation.number == start + 1, "batch cost more than one rebuild"


@contract("the cheap rebuild still catches a cross-document defect")
def test_cheap_rebuild_is_not_weaker(root: Path) -> None:
    workspace = Workspace(root)
    victim, donor = None, None
    for node in workspace.graph.iter_nodes():
        if node.reserved_uid:
            if donor is None:
                donor = node.reserved_uid
            elif node.reserved_uid != donor:
                victim = node.reserved_uid
                break
    assert victim and donor

    # POSITIVE CONTROL: the same harness accepts the corpus untouched.
    workspace.reconcile(Reconcile.GRAPH)

    # Now collide two UIDs across documents -- invisible to any single-file
    # parse, and exactly what the deferred rebuild exists to catch.
    workspace.graph.node(victim).set_field_value(field_name="UID", form_field_index=0, value=donor)
    try:
        workspace.reconcile(Reconcile.GRAPH)
    except WorkspaceError:
        return
    raise AssertionError("duplicate UID across documents was not caught by the rebuild")


@contract("a write that will not parse is rolled back, bytes and graph")
def test_rollback(root: Path) -> None:
    workspace = Workspace(root)
    uid = some_node(workspace)
    path = workspace.graph.path_of(workspace.graph.node(uid))
    original = path.read_text(encoding="utf8")
    generation = workspace.current()

    # A STATEMENT carrying the field terminator produces a document the
    # writer emits happily and the reader cannot read back.
    def poison(graph):
        graph.node(uid).set_field_value(
            field_name="STATEMENT", form_field_index=0, value="broken\n<<<\nTITLE: x\n"
        )
        graph._touch(graph.node(uid).get_document())

    try:
        workspace.write(poison)
    except WorkspaceError:
        pass
    else:
        raise AssertionError("an unparseable write was accepted")

    assert path.read_text(encoding="utf8") == original, "bytes were not restored"
    assert workspace._generation is None, "the mutated graph was kept after a failed write"

    # And the workspace serves correctly again, from disk.
    revived = workspace.current()
    assert revived.number == 1, "recovery did not re-derive from disk"
    assert revived.graph is not generation.graph
    assert field_value(revived.graph.node(uid), "STATEMENT") != "broken"


@contract("resolves() answers without forcing a reconcile")
def test_resolves_is_cheap(root: Path) -> None:
    workspace = Workspace(root)
    uid = some_node(workspace)
    workspace.write(lambda g: g.set_field(uid, "TITLE", "Still dirty"))
    generation = workspace._generation
    assert workspace.resolves(uid) is True
    assert workspace.resolves("MECH-NO-SUCH-NODE-EXISTS") is False
    assert workspace._generation is generation, "resolves() reconciled"


@contract("a failed rebuild leaves the previous generation serving")
def test_failed_rebuild_does_not_strand(root: Path) -> None:
    workspace = Workspace(root)
    good = workspace.current()
    uid = some_node(workspace)
    donor = next(
        n.reserved_uid for n in workspace.graph.iter_nodes()
        if n.reserved_uid and n.reserved_uid != uid
    )
    workspace.graph.node(uid).set_field_value(field_name="UID", form_field_index=0, value=donor)
    try:
        workspace.reconcile(Reconcile.GRAPH)
    except WorkspaceError:
        pass
    assert workspace._generation is good, "a failed rebuild replaced the live generation"


CONTRACTS = [
    test_read_is_free,
    test_write_defers,
    test_batch_pays_once,
    test_cheap_rebuild_is_not_weaker,
    test_rollback,
    test_resolves_is_cheap,
    test_failed_rebuild_does_not_strand,
]


def main() -> int:
    failures = 0
    for fn in CONTRACTS:
        with tempfile.TemporaryDirectory(prefix="scribe-workspace-") as tmp:
            root = corpus(Path(tmp) / "corpus")
            try:
                fn(root)
            except Exception as exc:  # noqa: BLE001 -- report all, then exit non-zero
                failures += 1
                print(f"  FAIL  {fn.__name__}: {type(exc).__name__}: {exc}")
    print(f"\n{len(PASSED)} passed, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
