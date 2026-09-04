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

import os
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
from sdoc_model import SdocError, field_value  # noqa: E402

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
    """Copy the tracked tree so every File relation remains resolvable.

    A hand-maintained subset drifted as soon as the canon gained a File edge
    outside dev/scripts. The export contract is specifically meant to catch
    integration drift, so its fixture has to include every tracked target.
    """
    repo = Path(__file__).resolve().parents[2]
    listed = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=repo, capture_output=True, text=True, check=True,
    ).stdout.split("\0")
    for name in filter(None, listed):
        source = repo / name
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        if source.is_symlink():
            target.symlink_to(os.readlink(source))
        else:
            shutil.copy2(source, target)
    assert (destination / "strictdoc_config.py").is_file()
    return destination


def any_node(workspace: Workspace) -> str:
    for node in workspace.graph.iter_nodes():
        if node.reserved_uid and field_value(node, "TITLE"):
            return node.reserved_uid
    raise AssertionError("corpus copy has no usable node")


# Every field DocumentMeta carries. The derived-versus-rebuilt comparison is
# what makes hand-mirroring DocumentFinder safe, so it must be exhaustive --
# a list that quietly omits a field is a contract that quietly stops checking.
META_FIELDS = (
    "level",
    "file_tree_mount_folder",
    "document_filename",
    "document_filename_base",
    "input_doc_full_path",
    "input_doc_rel_path",
    "input_doc_dir_rel_path",
    "input_doc_assets_dir_rel_path",
    "output_document_dir_full_path",
    "output_document_dir_rel_path",
    "output_document_full_path",
)


def meta_value(meta, name: str):
    """One meta field, unwrapped so it can be compared AND printed.

    SDocRelativePath defines no equality and raises AssertionError from both
    __str__ and __repr__, so comparing two of them is identity and an
    assertion message that interpolated one would die reporting the failure
    rather than reporting it.
    """
    value = getattr(meta, name)
    if hasattr(value, "relative_path"):
        return (value.relative_path, value.relative_path_posix)
    return value


def create(workspace: Workspace, path: Path, uid: str, tag: str = "MECHANISM", **overrides):
    """Create one node through the ordinary write path."""
    values = {
        "UID": uid,
        "TITLE": f"Contract node {uid}",
        "DEPTH": "sketch",
        "AUTHORED_BY": "llm",
        "STATEMENT": "Written by a contract.",
    }
    relations = overrides.pop("_relations", [])
    values.update(overrides)
    workspace.write(
        lambda g: g.add_node(
            g.new_document(path, values["TITLE"]), tag, values, relations
        ),
        precheck=refuse_dangling_links,
    )


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


@contract("a create is a deferred write, and a batch of them pays ONE reload")
def test_create_defers(root: Path) -> None:
    workspace = Workspace(root)
    plan = root / "docs" / "plans" / "scribe-daemon"
    start = workspace.current().number
    uids = [f"MECH-CONTRACT-BATCH-{n}" for n in range(3)]
    for uid in uids:
        create(workspace, plan / f"{uid.lower()}.sdoc", uid)
    assert workspace._generation.number == start, "a create inside the batch reloaded"
    assert workspace._dirty, "a create did not mark the graph dirty"
    for uid in uids:
        assert (plan / f"{uid.lower()}.sdoc").is_file(), f"{uid} was not written"

    after = workspace.current()
    assert after.number == start + 1, "the batch of creates cost more than one reload"
    for uid in uids:
        assert after.graph.has_node(uid), f"{uid} is missing after the reload"


@contract("a document built in memory is field-for-field what a rebuild builds")
def test_new_document_matches_rebuild(root: Path) -> None:
    workspace = Workspace(root)

    # Three depths, because every derived field is a join of the root's own
    # basename with the document's directory: a plan directory, a shallower
    # one, and the root itself, where the empty-directory branch is taken.
    paths = {
        "MECH-CONTRACT-DEEP": root / "docs" / "plans" / "scribe-daemon" / "mech-contract-deep.sdoc",
        "MECH-CONTRACT-MID": root / "docs" / "spec" / "mech-contract-mid.sdoc",
        "MECH-CONTRACT-ROOT": root / "mech-contract-root.sdoc",
    }
    for uid, path in paths.items():
        create(workspace, path, uid)

    held = workspace._held()
    built = {uid: held.index.document_tree.map_docs_by_paths[str(path)]
             for uid, path in paths.items()}

    # The grammar is the SHARED element list, not a copy of it. Checked by
    # identity against a document that came off the disk, which is the whole
    # reason the reload was avoidable.
    neighbour = next(d for d in held.documents if d not in built.values())
    for uid, document in built.items():
        assert document.grammar.elements is neighbour.grammar.elements, (
            f"{uid} got its own element list instead of the shared one"
        )
        assert set(document.grammar.elements_by_type) == set(
            neighbour.grammar.elements_by_type
        ), f"{uid} resolved a different set of element tags"

    renders = {uid: held.render(document) for uid, document in built.items()}

    rebuilt = workspace.reload().graph
    by_path = {Path(d.meta.input_doc_full_path): d for d in rebuilt.documents}
    for uid, path in paths.items():
        document = by_path.get(path)
        assert document is not None, f"{uid} is not in the rebuilt tree"
        mine, theirs = built[uid].meta, document.meta
        for name in META_FIELDS:
            assert meta_value(mine, name) == meta_value(theirs, name), (
                f"{uid}: meta field {name} differs from the rebuild: "
                f"{meta_value(mine, name)!r} vs {meta_value(theirs, name)!r}"
            )
        assert renders[uid] == rebuilt.render(document), (
            f"{uid} renders differently once it has been read back"
        )


@contract("a node created in a batch can be the next write's relation target")
def test_created_node_is_a_target(root: Path) -> None:
    workspace = Workspace(root)
    plan = root / "docs" / "plans" / "scribe-daemon"
    start = workspace.current().number
    create(workspace, plan / "mech-contract-lane.sdoc", "MECH-CONTRACT-LANE")
    create(
        workspace,
        plan / "work-contract-rider.sdoc",
        "WORK-CONTRACT-RIDER",
        tag="WORK",
        _relations=[("Crosses", "MECH-CONTRACT-LANE")],
    )
    assert workspace._generation.number == start, "the pair of creates reloaded"
    text = (plan / "work-contract-rider.sdoc").read_text(encoding="utf8")
    assert "MECH-CONTRACT-LANE" in text, "the relation to the fresh node was lost"


@contract("a refused create leaves no file behind")
def test_refused_create_leaves_nothing(root: Path) -> None:
    workspace = Workspace(root)
    plan = root / "docs" / "plans" / "scribe-daemon"

    # POSITIVE CONTROL: the same call with a resolvable link is accepted.
    other = any_node(workspace)
    good = plan / "mech-contract-sound.sdoc"
    create(
        workspace, good, "MECH-CONTRACT-SOUND",
        STATEMENT=f"Points at [LINK: {other}] which exists.",
    )
    assert good.is_file(), "positive control failed: a sound create wrote nothing"

    bad = plan / "mech-contract-dangling.sdoc"
    try:
        create(
            workspace, bad, "MECH-CONTRACT-DANGLING",
            STATEMENT="Points at [LINK: NO-SUCH-UID-ANYWHERE].",
        )
    except WorkspaceError as exc:
        assert "NO-SUCH-UID-ANYWHERE" in str(exc)
        assert not bad.exists(), "a refused create left a skeleton on disk"
        return
    raise AssertionError("a create carrying a dangling inline link was accepted")


@contract("a create the loader could not read back is refused, not silently lost")
def test_unreadable_destination_refused(root: Path) -> None:
    workspace = Workspace(root)

    # POSITIVE CONTROL: the same node one directory over is accepted AND is
    # still there after the reload -- which is what the refusal below is
    # protecting, and what the assertion on `output/` cannot show by itself.
    good = root / "docs" / "plans" / "scribe-daemon" / "mech-contract-kept.sdoc"
    create(workspace, good, "MECH-CONTRACT-KEPT")
    assert workspace.current().graph.has_node("MECH-CONTRACT-KEPT"), (
        "positive control failed: an ordinary create did not survive the reload"
    )

    # strictdoc prunes `output` and `Output` from its walk unconditionally, so
    # a document written there is written and then simply gone. Measured with
    # the guard removed: the file lands on disk and has_node is False after the
    # next reload.
    lost = root / "output" / "mech-contract-lost.sdoc"
    try:
        create(workspace, lost, "MECH-CONTRACT-LOST")
    except WorkspaceError as exc:
        assert "never reads" in str(exc), f"refused for the wrong reason: {exc}"
        assert not lost.exists(), "a refused create wrote the file anyway"
        return
    raise AssertionError("a create into an unread directory was accepted")


@contract("apply dry-run returns a diff without changing disk or held state")
def test_apply_dry_run(root: Path) -> None:
    import scribe_ops

    workspace = Workspace(root)
    uid = any_node(workspace)
    path = workspace.graph.path_of(workspace.graph.node(uid))
    before_read = scribe_ops.apply(workspace, "show", {"op": "show", "uid": uid})
    before_bytes = path.read_bytes()
    before_mtime = path.stat().st_mtime_ns
    params = {
        "op": "set",
        "uid": uid,
        "fields": {"TITLE": "A dry-run contract title"},
        "unset": [],
    }

    preview = scribe_ops.apply(workspace, "set", {**params, "dry_run": True})
    assert preview["written"] == []
    assert f"--- a/{path.relative_to(root)}" in preview["text"]
    assert "+TITLE: A dry-run contract title" in preview["text"]
    assert path.read_bytes() == before_bytes, "dry-run changed the file bytes"
    assert path.stat().st_mtime_ns == before_mtime, "dry-run changed the file mtime"
    after_read = scribe_ops.apply(workspace, "show", {"op": "show", "uid": uid})
    assert after_read == before_read, "dry-run changed the daemon's held state"

    # POSITIVE CONTROL: the identical operation without dry-run writes.
    written = scribe_ops.apply(workspace, "set", params)
    assert written["written"] == [str(path.relative_to(root))]
    assert path.read_bytes() != before_bytes, "the real operation did not change bytes"
    assert path.stat().st_mtime_ns != before_mtime, "the real operation did not change mtime"


@contract("dry-run refuses the same invalid change as a real write")
def test_apply_dry_run_refusal(root: Path) -> None:
    import scribe_ops

    workspace = Workspace(root)
    uid = any_node(workspace)
    path = workspace.graph.path_of(workspace.graph.node(uid))
    original = path.read_bytes()
    params = {
        "op": "set",
        "uid": uid,
        "fields": {"STATEMENT": "Points at [LINK: NO-SUCH-DRY-RUN-UID]."},
        "unset": [],
    }
    messages = []
    for dry_run in (True, False):
        try:
            scribe_ops.apply(workspace, "set", {**params, "dry_run": dry_run})
        except WorkspaceError as exc:
            messages.append(str(exc))
        else:
            raise AssertionError(f"the invalid {'dry' if dry_run else 'real'} write passed")
        assert path.read_bytes() == original, "a refused operation changed bytes"
    assert messages[0] == messages[1], "dry-run and real write refused differently"


@contract("an empty dry-run diff says nothing would change")
def test_apply_dry_run_empty(root: Path) -> None:
    import scribe_ops

    workspace = Workspace(root)
    uid = any_node(workspace)
    node = workspace.graph.node(uid)
    path = workspace.graph.path_of(node)
    original = path.read_bytes()
    mtime = path.stat().st_mtime_ns
    params = {
        "op": "set",
        "uid": uid,
        "fields": {"TITLE": field_value(node, "TITLE")},
        "unset": [],
    }
    preview = scribe_ops.apply(workspace, "set", {**params, "dry_run": True})
    assert preview["text"] == "nothing would change\n"
    assert path.read_bytes() == original
    assert path.stat().st_mtime_ns == mtime

    # POSITIVE CONTROL: the identical real operation reaches the save path.
    written = scribe_ops.apply(workspace, "set", params)
    assert written["written"] == [str(path.relative_to(root))]
    assert path.read_bytes() == original, "the no-op real write changed canonical bytes"
    assert path.stat().st_mtime_ns != mtime, "the real write did not replace the file"


@contract("new and move dry-runs leave no path, directory, temp file or rename")
def test_apply_dry_run_paths(root: Path) -> None:
    import scribe_ops

    workspace = Workspace(root)
    created = root / "docs" / "plans" / "dry-run-contract" / "work-contract-new.sdoc"
    create_params = {
        "op": "new",
        "type": "WORK",
        "uid": "WORK-CONTRACT-NEW",
        "fields": {
            "TITLE": "Dry-run create contract",
            "DEPTH": "sketch",
            "STATEMENT": "A proposed node.",
        },
        "relations": [],
        "path": str(created),
    }
    before_temps = set(root.rglob("*.sdoc-tmp"))
    preview = scribe_ops.apply(workspace, "new", {**create_params, "dry_run": True})
    assert f"+++ b/{created.relative_to(root)}" in preview["text"]
    assert not created.exists(), "dry-run create wrote its file"
    assert not created.parent.exists(), "dry-run create made its directory"
    assert set(root.rglob("*.sdoc-tmp")) == before_temps, "dry-run left a temp file"

    # POSITIVE CONTROL: the identical create without dry-run writes the path.
    scribe_ops.apply(workspace, "new", create_params)
    assert created.is_file(), "the real create did not write its file"

    moved = root / "docs" / "plans" / "dry-run-moved" / created.name
    before_bytes = created.read_bytes()
    before_mtime = created.stat().st_mtime_ns
    move_params = {"op": "move", "uid": "WORK-CONTRACT-NEW", "path": str(moved)}
    preview = scribe_ops.apply(workspace, "move", {**move_params, "dry_run": True})
    assert preview["text"] == (
        f"move {created.relative_to(root)} -> {moved.relative_to(root)}\n"
    )
    assert created.read_bytes() == before_bytes, "dry-run move changed the source bytes"
    assert created.stat().st_mtime_ns == before_mtime, "dry-run move changed the source mtime"
    assert not moved.exists(), "dry-run move renamed the file"
    assert not moved.parent.exists(), "dry-run move made the destination directory"
    assert set(root.rglob("*.sdoc-tmp")) == before_temps, "dry-run move left a temp file"

    # POSITIVE CONTROL: the identical move without dry-run performs the rename.
    scribe_ops.apply(workspace, "move", move_params)
    assert not created.exists(), "the real move left its source behind"
    assert moved.read_bytes() == before_bytes, "the real move changed the file bytes"
    assert moved.stat().st_mtime_ns == before_mtime, "the real move changed the file mtime"


@contract("a File relation names an item, through the daemon's own op path")
def test_file_relation_names_an_item(root: Path) -> None:
    """WORK-SCRIBE-RELATE-FILE-ROLE, and the export slots with it.

    Goes through scribe_ops.apply rather than Graph directly, because the
    defect was there and nowhere else: `File` is the role a client NAMES and
    the empty string is the role the GRAMMAR declares, and this branch passed
    the client's spelling straight through. The command line mapped it and
    worked; every File relation through the daemon was refused as a role the
    node's type does not declare.
    """
    import json

    import scribe_ops

    workspace = Workspace(root)
    uid = "MECH-CONTRACT-FILE-ITEM"
    create(workspace, root / "docs" / "plans" / "scribe-daemon" / "mech-item.sdoc", uid)
    target = root / "dev" / "scripts" / "contract_target.nix"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("{ config, ... }: { processes.scribe = { }; }\n", encoding="utf8")
    relative = "dev/scripts/contract_target.nix"

    def relate(**extra):
        return scribe_ops.apply(
            workspace,
            "relate",
            {"op": "relate", "uid": uid, "role": "File", "target": relative, **extra},
        )

    # POSITIVE CONTROL: the whole-file relation the corpus already writes.
    relate()
    # Then the SAME file again, named down to one item in it. Refusing this
    # as a duplicate is what keying the relation on its path alone did.
    relate(element="function", id="processes.scribe")

    written = (root / "docs" / "plans" / "scribe-daemon" / "mech-item.sdoc").read_text(
        encoding="utf8"
    )
    assert "  ELEMENT: function\n  ID: processes.scribe\n" in written, (
        f"the item slots did not reach the file:\n{written}"
    )

    for label, extra in (
        ("the identical relation twice", {"element": "function", "id": "processes.scribe"}),
        ("an element naming no item", {"element": "function"}),
        ("an element strictdoc does not parse", {"element": "module", "id": "x"}),
        ("an item AND a line range", {"element": "function", "id": "y", "line_range": "1-2"}),
    ):
        try:
            relate(**extra)
        except SdocError:
            continue
        raise AssertionError(f"accepted {label}")

    # The export is the board's only input, and strictdoc's own generator
    # reads neither slot off a FileReference.
    exported = workspace.export_json(root / "export")
    index = json.loads(Path(exported["index"]).read_text(encoding="utf8"))
    relations = [
        relation
        for document in index["DOCUMENTS"]
        for node in document.get("NODES", [])
        if node.get("UID") == uid
        for relation in node.get("RELATIONS", [])
    ]
    assert {"TYPE": "File", "VALUE": relative} in relations, (
        f"the whole-file relation is missing from the export: {relations}"
    )
    assert {
        "TYPE": "File",
        "VALUE": relative,
        "ELEMENT": "function",
        "ID": "processes.scribe",
    } in relations, f"the export dropped the item slots: {relations}"


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
    test_create_defers,
    test_new_document_matches_rebuild,
    test_created_node_is_a_target,
    test_refused_create_leaves_nothing,
    test_unreadable_destination_refused,
    test_apply_dry_run,
    test_apply_dry_run_refusal,
    test_apply_dry_run_empty,
    test_apply_dry_run_paths,
    test_file_relation_names_an_item,
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
