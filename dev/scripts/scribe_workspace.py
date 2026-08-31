#!/usr/bin/env python3
# cspell:ignore uids sdoc unpickle
"""scribe_workspace -- one held graph per workspace, and the reconciliation
that lets a write defer its cost (MECH-SCRIBE-WORKSPACE,
MECH-SCRIBE-RECONCILE, docs/plans/scribe-daemon/).

The point of holding the graph is that loading it dominates everything else:
one load is about 0.95 s on this corpus, `scribe show` is 1.05 s wall, and
`scribe new` pays THREE loads (EV-SCRIBE-LOAD-COST). A resident process pays
that once.

WHAT A WRITE COSTS, and why the split is what makes deferral safe
-----------------------------------------------------------------
A write does two checks at two different times.

Immediately, per write: the bytes just written are re-parsed ON THEIR OWN.
That is about 0.4 ms and it catches a document that will not parse, naming
the write that caused it. It cannot see anything cross-document.

Deferred, at the next operation needing a consistent whole-graph view: the
graph is rebuilt. That catches duplicate UIDs, dangling relation targets and
missing required fields -- the things one document cannot know about itself.
A run of writes therefore pays ONE rebuild rather than one each, which is the
whole batching win (DEC-SCRIBE-DEFERS-THE-REBUILD).

TWO RECONCILE LEVELS, and why the cheap one is not a weaker check
-----------------------------------------------------------------
`create_from_document_tree` is not a shortcut around the full build -- it is
literally the second half of it. `TraceabilityIndexBuilder.create` is
`DocumentFinder.find_sdoc_content` (~337 ms: walking the tree and unpickling
348 documents) followed by `create_from_document_tree` (~20 ms: building the
graph over those parsed objects). Re-running only the second half over
documents we already hold re-derives every cross-document invariant, because
those all live in the second half.

It cannot see a document that ARRIVED or LEFT, though, because the document
set comes from the walk. So:

    GRAPH  ~20 ms   field and relation edits -- the document set is unchanged
    FULL   ~500 ms  a document was created or deleted

FULL is strictdoc's own documented path. Hand-inserting into DocumentTree's
containers would make it ~25 ms, and it is deliberately NOT done here: the
containers have no maintainer, a DocumentMeta has to be fabricated, and
batching already amortized the difference away. `scribe new` in a batch of ten
costs about 505 ms total either way.

RECOVERY, which is the thing a one-shot command never needed
------------------------------------------------------------
`scribe`'s current verify restores file BYTES when a reload fails. That is
sufficient for a process that is about to exit and wrong for one that is not:
restoring bytes leaves the in-memory graph half-mutated, and a daemon would
keep answering from it. So a failed write here restores the bytes AND drops
the mutated graph, re-deriving it before anything is served again.

TWO TRAPS
---------
`TraceabilityIndexBuilder` calls `sys.exit(1)` on four failure paths and
RAISES on others, so both have to be caught -- and `sys.exit` in a daemon
kills the process rather than the command.

Every graph-database invariant is a bare `assert`, so this must never run
under `python -O`, where they vanish and a corrupt index passes silently.
"""

from __future__ import annotations

import contextlib
import io
import os
import sys
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))

from sdoc_model import Graph, SdocError, open_graph  # noqa: E402

from strictdoc.backend.sdoc.reader import SDReader  # noqa: E402
from strictdoc.core.traceability_index_builder import (  # noqa: E402
    TraceabilityIndexBuilder,
)

if not __debug__:  # pragma: no cover -- the guard exists to be loud, not run
    raise SystemExit(
        "scribe_workspace refuses to run under python -O: strictdoc's graph "
        "invariants are bare asserts, so optimization turns a corrupt index "
        "into a silent one."
    )


class Reconcile(Enum):
    """How much of the load a pending change forces us to redo."""

    NONE = "none"
    GRAPH = "graph"
    FULL = "full"

    @property
    def rank(self) -> int:
        return {"none": 0, "graph": 1, "full": 2}[self.value]


@dataclass(frozen=True)
class Generation:
    """One consistent state. Immutable so a reader that took it keeps it
    while a writer builds the replacement."""

    number: int
    graph: Graph


class WorkspaceError(SdocError):
    """A write that could not be applied, after the tree was put back."""


class Workspace:
    """Holds one project root's graph and republishes it as generations.

    Readers take `current()`, which reconciles first if a write left the
    graph dirty. Writers go through `write()`, which owns the whole
    apply-save-verify-or-restore cycle.
    """

    def __init__(self, root: Path, *, output_dir: Path | None = None) -> None:
        self.root = Path(root).resolve()
        self.output_dir = output_dir
        self._generation: Generation | None = None
        self._pending = Reconcile.NONE

    # ---- reading -------------------------------------------------------

    def current(self) -> Generation:
        """The generation a reader should see, reconciled if it has to be."""
        if self._generation is None:
            self._generation = Generation(1, self._load_full())
            self._pending = Reconcile.NONE
        elif self._pending is not Reconcile.NONE:
            self._republish(self._rebuild(self._pending))
        return self._generation

    @property
    def graph(self) -> Graph:
        return self.current().graph

    def _held(self) -> Graph:
        """The graph as held, WITHOUT reconciling.

        This is what a write mutates. Going through `current()` here would
        reconcile on the second write of a batch and undo the whole point of
        deferring: a mutation edits nodes in memory and does not need the
        cross-document view that a read does.
        """
        if self._generation is None:
            self._generation = Generation(1, self._load_full())
            self._pending = Reconcile.NONE
        return self._generation.graph

    def resolves(self, uid: str) -> bool:
        """Whether a UID is known WITHOUT forcing a reconcile.

        The caller uses this to decide whether a relation target needs the
        deferred rebuild pulled forward: a node created earlier in the same
        batch is not in the index yet, and reconciling on the miss is what
        keeps the batching advice advisory rather than load-bearing.
        """
        return self._held().has_node(uid)

    def describe(self) -> dict:
        state = self.current()
        return {
            "root": str(self.root),
            "generation": state.number,
            "pending": self._pending.value,
            "nodes": sum(1 for _ in state.graph.iter_nodes()),
            "documents": len(state.graph.documents),
        }

    # ---- writing -------------------------------------------------------

    def write(self, mutate: Callable[[Graph], None], *, level: Reconcile = Reconcile.GRAPH):
        """Apply `mutate` to the held graph, save it, and prove it parsed.

        `level` is what the mutation costs to reconcile: GRAPH for field and
        relation edits, FULL when it creates or deletes a document. The
        rebuild itself is DEFERRED -- only the per-file parse runs here.

        On any failure the written files are restored to their previous
        bytes and the mutated graph is dropped, so the next read re-derives
        from disk rather than serving a half-applied index.
        """
        return self._attempt(mutate, level, retried=False)

    def _attempt(self, mutate, level: Reconcile, *, retried: bool):
        deferred = self._pending
        graph = self._held()
        restore: dict[Path, str | None] = {}
        try:
            mutate(graph)
            for path in graph.pending():
                restore[path] = path.read_text(encoding="utf8") if path.exists() else None
            written = graph.save()
            for path in written:
                self._parse_one(path)
        except BaseException as exc:  # SystemExit included -- see module docstring
            self._restore(restore)
            # Drop the graph, not just the bytes. A partially applied mutation
            # lives in the document objects, and a GRAPH-level rebuild REUSES
            # those objects -- so only re-deriving from disk actually undoes it.
            self._generation = None
            self._pending = Reconcile.NONE
            if not retried and deferred is not Reconcile.NONE:
                # The likeliest cause is a reference the deferred rebuild had
                # not yet made resolvable -- a node created earlier in this
                # same batch. Re-derive and try once. This is what keeps the
                # "group your writes" advice advisory: batching badly costs a
                # rebuild that was owed anyway, and nothing breaks.
                return self._attempt(mutate, level, retried=True)
            raise WorkspaceError(f"write rolled back: {exc}") from exc
        self._pending = max(self._pending, level, key=lambda r: r.rank)
        return written

    def reconcile(self, level: Reconcile | None = None) -> Generation:
        """Rebuild now rather than at the next read."""
        wanted = level or (self._pending if self._pending is not Reconcile.NONE else Reconcile.GRAPH)
        if self._generation is None:
            return self.current()
        return self._republish(self._rebuild(wanted))

    # ---- internals -----------------------------------------------------

    def _republish(self, graph: Graph) -> Generation:
        number = 1 if self._generation is None else self._generation.number + 1
        self._generation = Generation(number, graph)
        self._pending = Reconcile.NONE
        return self._generation

    def _rebuild(self, level: Reconcile) -> Graph:
        """Construct a REPLACEMENT graph. Never mutates the live one, so a
        failure here leaves the previous generation serving."""
        if level is Reconcile.FULL or self._generation is None:
            return self._load_full()
        held = self._generation.graph
        index = self._guarded(
            lambda: TraceabilityIndexBuilder.create_from_document_tree(
                held.index.document_tree, held.config
            )
        )
        return Graph(held.root, held.config, index)

    def _load_full(self) -> Graph:
        return self._guarded(lambda: open_graph(self.root, output_dir=self.output_dir))

    @staticmethod
    def _guarded(build):
        """Run a strictdoc build, converting its two failure styles into one.

        The builder narrates on stdout and, on four paths, calls sys.exit(1)
        instead of raising -- which would take a daemon down. Both become a
        WorkspaceError carrying whatever the builder printed.
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
            raise WorkspaceError(
                f"{exc}\n{chatter.getvalue().strip()}".strip()
            ) from exc

    def _parse_one(self, path: Path) -> None:
        """Re-parse ONE written file from disk, bypassing the pickle cache.

        `SDReader.read_from_file` consults PickleCache, which would let a
        stale entry answer for bytes we just wrote and make this check
        vacuous. Reading the text back and parsing the string cannot.
        """
        if not path.exists():  # a deletion has nothing to parse
            return
        text = path.read_text(encoding="utf8")
        try:
            SDReader.read(text, str(path))
        except BaseException as exc:
            raise WorkspaceError(f"{path} does not parse after the write: {exc}") from exc

    @staticmethod
    def _restore(restore: dict[Path, str | None]) -> None:
        for path, text in restore.items():
            if text is None:
                with contextlib.suppress(FileNotFoundError):
                    os.unlink(path)
            else:
                path.write_text(text, encoding="utf8")
