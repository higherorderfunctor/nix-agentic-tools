#!/usr/bin/env python3
# cspell:ignore uids sdoc unpickle precheck prechecks
"""scribe_workspace -- one held graph per workspace (MECH-SCRIBE-WORKSPACE,
MECH-SCRIBE-RECONCILE, docs/plans/scribe-daemon/).

Loading dominates everything else: one load is ~0.55 s and `scribe show` was
1.05 s wall. A resident process pays once, and every verb -- `new` included --
is a write against the held graph.

NOTHING IS WRITTEN UNTIL IT IS KNOWN TO BE VALID
------------------------------------------------
A write applies the mutation in memory, checks it, renders each touched
document to a STRING and parses that string -- and only then touches the
disk. A rejected write never moved a byte, so there is nothing to undo.

This replaces an earlier shape here that wrote first and restored the bytes
on failure. Rollback survives as a net under `save()` itself, but no logic
above it is allowed to depend on rollback having happened: the moment a
caller assumes an undo it did not read, a wrong assumption starts costing
real corpus damage.

THE DEFERRED RELOAD IS A FULL ONE, AND THAT IS NOT NEGOTIABLE
-------------------------------------------------------------
An earlier version deferred to `create_from_document_tree` (~20 ms) on the
belief that it re-derives every cross-document invariant. IT DOES NOT.
Inline `[LINK: UID]` references are APPENDED to `pending_inline_links` inside
that function and drained and validated only in the outer `create()`
(traceability_index_builder.py:266-278).

Measured on this corpus: after a full load, `pending_inline_links` is 0 and
242 nodes carry incoming links; after the cheap rebuild it is 579 and ZERO
nodes do. There are 579 inline links across 59 files, and 10 UIDs that
nothing but a `[LINK:]` names. So the cheap rebuild would accept deleting a
node the canon still points at.

The cheap level is therefore GONE rather than demoted. A tempting-but-unsound
option left in the code is a defect waiting for someone in a hurry.

Batching is unaffected, which was the point of deferring: N writes cost ~10 ms
each and the next read pays ONE reload. Ten writes then a read is ~0.65 s
against ~30 s through the one-shot command.

TWO TRAPS
---------
`TraceabilityIndexBuilder` calls `sys.exit(1)` on four paths and RAISES on
others, so both must be caught -- and `sys.exit` in a daemon kills the
process rather than the command.

Every graph-database invariant is a bare `assert`, so this must never run
under `python -O`, where they vanish and a corrupt index passes silently.
"""

from __future__ import annotations

import contextlib
import hashlib
import io
import os
import sys
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))

from sdoc_model import (  # noqa: E402
    Graph,
    SdocError,
    carry_file_element_into_json,
    open_graph,
)

from strictdoc.backend.sdoc.reader import SDReader  # noqa: E402

if not __debug__:  # pragma: no cover -- the guard exists to be loud, not run
    raise SystemExit(
        "scribe_workspace refuses to run under python -O: strictdoc's graph "
        "invariants are bare asserts, so optimization turns a corrupt index "
        "into a silent one."
    )

# What a freshness sweep looks at. The grammar and the project config change
# what parses, so a change to either invalidates the held graph as surely as
# a node edit does.
WATCHED_SUFFIXES = (".sdoc", ".sgra")
WATCHED_FILES = ("strictdoc_config.py",)


@dataclass(frozen=True)
class Generation:
    """One consistent state. Immutable, so a reader that took it keeps it
    while a writer builds the replacement."""

    number: int
    graph: Graph
    fingerprint: str


@dataclass(frozen=True)
class WriteResult:
    """The rendered proposal and the paths a real write replaced."""

    pending: dict[Path, str | None]
    written: tuple[Path, ...]


class WorkspaceError(SdocError):
    """A write that was refused, or a graph that would not build."""


class Workspace:
    """Holds one project root's graph and republishes it as generations."""

    def __init__(self, root: Path, *, output_dir: Path | None = None) -> None:
        self.root = Path(root).resolve()
        self.output_dir = output_dir
        self._generation: Generation | None = None
        self._dirty = False
        # One writer at a time. Reads take an immutable generation and need
        # no lock; this exists because the daemon is a threading server and
        # two concurrent writes share Graph._dirty, which loses both.
        self._lock = threading.RLock()

    # ---- reading -------------------------------------------------------

    def current(self) -> Generation:
        """The generation a reader should see.

        Reloads when our own writes left the graph dirty, AND when the files
        changed underneath us. The second is not hypothetical: git rewrites
        the tree during a checkout or rebase, and the daemon is not the one
        running git.
        """
        with self._lock:
            if self._generation is None or self._dirty or self._changed_on_disk():
                self._republish(self._load_full())
            return self._generation

    @property
    def graph(self) -> Graph:
        return self.current().graph

    def _held(self) -> Graph:
        """The graph as held, WITHOUT reloading.

        What a write mutates. Going through `current()` here would reload on
        the second write of a batch and undo the point of deferring.
        """
        with self._lock:
            if self._generation is None:
                self._republish(self._load_full())
            return self._generation.graph

    def describe(self) -> dict:
        state = self.current()
        return {
            "root": str(self.root),
            "generation": state.number,
            "dirty": self._dirty,
            "nodes": sum(1 for _ in state.graph.iter_nodes()),
            "documents": len(state.graph.documents),
        }

    def export_json(self, output_dir: Path) -> dict:
        """Write the export JSON from the held graph (MECH-SCRIBE-EXPORT-PAYLOAD).

        StrictDoc's JSON generator is a pure function of a built index -- its
        own server calls it against the live one -- so this walks objects
        already in memory instead of the 1.76 s `strictdoc export` the render
        pays today, all of which is that command's own graph load. Layout
        matches `strictdoc export --output-dir`, so downstream consumers read
        the same bytes at the same path.

        A read, so it reloads first if it has to.
        """
        from strictdoc.backend.json.json_generator import JSONGenerator

        # An element-grained File relation exports as a whole-file one
        # otherwise: the generator reads neither ELEMENT nor ID off a
        # FileReference. Idempotent, so a second export does not re-wrap.
        carry_file_element_into_json()

        state = self.current()
        destination = Path(output_dir).expanduser().resolve() / "json"
        destination.mkdir(parents=True, exist_ok=True)
        self._guarded(
            lambda: JSONGenerator().export_tree(
                state.graph.index, state.graph.config, str(destination)
            )
        )
        written = destination / "index.json"
        return {
            "root": str(self.root),
            "generation": state.number,
            "outputDir": str(destination),
            "index": str(written),
            "bytes": written.stat().st_size,
        }

    # ---- writing -------------------------------------------------------

    def write(
        self,
        mutate: Callable[[Graph], None],
        *,
        precheck: Callable[[Graph], None] | None = None,
        dry_run: bool = False,
    ) -> WriteResult:
        """Apply and check, then either preview or save.

        `mutate` edits the held graph in memory. `precheck` runs after it and
        raises to refuse -- it is where a cross-document rule lives that can
        be answered from the index without a reload, such as refusing to
        delete a node something still links to.

        Then every touched document is rendered to a string and that string
        is parsed. A document that would not read back is refused here, with
        the disk untouched.

        A dry run captures the rendered proposal and discards the mutated
        generation. Its next read reloads unchanged disk, so no speculative
        state survives the reply. A real write defers that reload as before,
        so a batch pays it once.
        """
        with self._lock:
            graph = self._held()
            try:
                mutate(graph)
                if precheck is not None:
                    precheck(graph)
                self._prove_renders(graph)
            except BaseException as exc:  # SystemExit included
                # Nothing was written. But the graph now holds a partial
                # mutation, and only re-deriving from disk undoes that.
                self._discard()
                raise WorkspaceError(str(exc)) from exc

            pending = graph.pending()
            if dry_run:
                self._discard()
                return WriteResult(pending, ())

            restore = {
                path: path.read_text(encoding="utf8") if path.exists() else None
                for path in pending
            }
            try:
                written = graph.save()
            except BaseException as exc:
                # The net, and the only place one is warranted: save() is
                # partway through the filesystem and no check can prevent
                # that. Nothing above here relies on this running.
                self._restore(restore)
                self._discard()
                raise WorkspaceError(f"save failed and was rolled back: {exc}") from exc

            self._dirty = True
            return WriteResult(pending, tuple(written))

    def reload(self) -> Generation:
        """Rebuild now rather than at the next read."""
        with self._lock:
            return self._republish(self._load_full())

    # ---- internals -----------------------------------------------------

    def _prove_renders(self, graph: Graph) -> None:
        """Render each touched document and parse the result, in memory.

        `SDReader.read_from_file` consults the pickle cache, which would let
        a stale entry answer for bytes we are about to write. Parsing the
        rendered string cannot, and it happens before the write rather than
        after it.
        """
        for path, content in graph.pending().items():
            if content is None:  # a deletion renders nothing
                continue
            try:
                SDReader.read(content, str(path))
            except BaseException as exc:
                raise WorkspaceError(f"{path} would not parse back: {exc}") from exc

    def _discard(self) -> None:
        """Drop the held graph so the next read re-derives from disk.

        Clearing BOTH fields is load-bearing. An earlier version left them
        set on a failed rebuild, which wedged the workspace permanently:
        every later read failed, and repairing the file on disk did not help
        because the rebuild ran over the in-memory objects.
        """
        self._generation = None
        self._dirty = False

    def _republish(self, graph: Graph) -> Generation:
        number = 1 if self._generation is None else self._generation.number + 1
        self._generation = Generation(number, graph, self._fingerprint())
        self._dirty = False
        return self._generation

    def _load_full(self) -> Graph:
        try:
            return self._guarded(lambda: open_graph(self.root, output_dir=self.output_dir))
        except BaseException:
            self._discard()
            raise

    def _changed_on_disk(self) -> bool:
        if self._generation is None:
            return True
        return self._fingerprint() != self._generation.fingerprint

    def _fingerprint(self) -> str:
        """A content hash over every file that decides what the graph is.

        Content rather than mtime: mtimes are not trustworthy here --
        strictdoc's own transforms layer stamps every document on an edit --
        and a hash costs about 7 ms over this corpus against a 550 ms
        reload, so the precision is nearly free.
        """
        digest = hashlib.sha256()
        for path in sorted(self._watched()):
            digest.update(str(path.relative_to(self.root)).encode("utf-8"))
            try:
                digest.update(path.read_bytes())
            except OSError:
                digest.update(b"\0missing")
        return digest.hexdigest()

    def _watched(self):
        for dirpath, dirnames, filenames in os.walk(self.root):
            dirnames[:] = [
                d for d in dirnames
                if d not in (".git", ".devenv", "output", "__pycache__", "node_modules")
            ]
            for name in filenames:
                if name.endswith(WATCHED_SUFFIXES) or name in WATCHED_FILES:
                    yield Path(dirpath) / name

    @staticmethod
    def _guarded(build):
        """Run a strictdoc build, converting its two failure styles into one.

        The builder narrates on stdout and, on four paths, calls sys.exit(1)
        instead of raising -- which would take a daemon down.
        """
        chatter = io.StringIO()
        try:
            with contextlib.redirect_stdout(chatter):
                return build()
        except SystemExit as exc:
            raise WorkspaceError(
                f"strictdoc exited during the build: {chatter.getvalue().strip()}"
            ) from exc
        except Exception as exc:
            raise WorkspaceError(f"{exc}\n{chatter.getvalue().strip()}".strip()) from exc

    @staticmethod
    def _restore(restore: dict[Path, str | None]) -> None:
        for path, text in restore.items():
            if text is None:
                with contextlib.suppress(FileNotFoundError):
                    os.unlink(path)
            else:
                path.write_text(text, encoding="utf8")


# ---- prechecks ---------------------------------------------------------
#
# Cross-document rules answerable from the held index, so a bad write is
# REFUSED rather than written and undone. These are the ones the deferred
# reload would otherwise catch late; it stays as the backstop for whatever
# is not enumerated here.


def refuse_if_referenced(uid: str) -> Callable[[Graph], None]:
    """Refuse to delete a node the canon still points at.

    Both directions matter and only the pair is sufficient: relations are
    what `create_from_document_tree` checks, and inline `[LINK:]` references
    are what it does NOT -- 10 UIDs in this corpus are named by nothing else.
    """

    def check(graph: Graph) -> None:
        index = graph.index
        node = index.get_node_by_uid_weak2(uid) if hasattr(index, "get_node_by_uid_weak2") else None
        if node is None:
            return
        referrers = []
        with contextlib.suppress(Exception):
            referrers += [n.reserved_uid for n in index.get_children_requirements(node)]
        with contextlib.suppress(Exception):
            referrers += [
                getattr(link, "parent_node_uid", None) or "an inline link"
                for link in index.get_incoming_links(node) or []
            ]
        if referrers:
            named = ", ".join(sorted({str(r) for r in referrers if r})[:5])
            raise WorkspaceError(
                f"{uid} is still referenced by {named} -- remove those references first"
            )

    return check


def refuse_dangling_links(graph: Graph) -> None:
    """Refuse a write whose prose names a `[LINK: UID]` that does not exist.

    This is the class the cheap rebuild silently accepted: a bogus link in a
    STATEMENT parses fine as a document and is only caught when the outer
    build drains pending_inline_links.
    """
    import re

    pattern = re.compile(r"\[LINK:\s*([A-Za-z0-9._-]+)\s*\]")
    for _path, content in graph.pending().items():
        if content is None:
            continue
        for uid in pattern.findall(content):
            if not graph.has_node(uid):
                raise WorkspaceError(f"[LINK: {uid}] names a node that does not exist")
