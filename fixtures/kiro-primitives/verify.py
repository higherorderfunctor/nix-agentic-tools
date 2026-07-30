#!/usr/bin/env python3
"""EXPECT.md's predicates, executable.

Three subcommands:

  reconstruct  rebuild the execution forest of every v3 session from the
               transcripts on disk, read-only, and print a stamped census.
  check        evaluate the EXPECT.md predicates against a run-state file,
               and cross-check its declared worker forest against the
               reconstruction.
  self-test     run both of the above over synthetic corpora whose answers are
               known, including deliberately dropped and deliberately
               double-worked runs, and assert the per-check verdicts.
  mutants      break one piece of predicate logic at a time and demand that
               `self-test` notices. A surviving mutant is an unverified
               predicate; this is what keeps `self-test` from being decoration.

READ-ONLY with respect to Kiro state. Nothing here opens a file under the
sessions root for writing; `self-test` builds its fixtures in a temp directory
and refuses to run if that directory resolves under ~/.kiro.

--------------------------------------------------------------------------
THE ONE THING TO READ BEFORE CHANGING THE RECONSTRUCTION
--------------------------------------------------------------------------

`payload.parentExecutionId` is NOT the nesting edge, even though its name says
it is. On this machine, every nested dispatch row carries the same
`parentExecutionId` as the ROOT dispatch row that created the dispatching
child -- i.e. it names the root turn's execution, not the immediate parent.
Measured 2026-07-29: 7 of 7 nested dispatchers, `parentExecutionId` identical
to their own root dispatch row's; and across the whole corpus 0 of 617 child
execution ids ever appear as a `parentExecutionId`.

So a forest built from `parentExecutionId` is FLAT by construction: every
worker reads as root-spawned. That is the very same collapse the interactive
display performs, which makes the naive method a false confirmation -- it
agrees with the display, and both are wrong.

The only nesting edge on disk is WHICH FILE the dispatch row lives in:

  a `sub_agent_start` row in <session>/messages.jsonl
      -> the dispatcher is the root session
  a `sub_agent_start` row in <session>/sub-executions/<X>.jsonl
      -> the dispatcher is execution X

`reconstruct` computes BOTH forests and prints both depths side by side,
precisely so the naive method's flattening stays visible as a control rather
than becoming a bug someone reintroduces.

--------------------------------------------------------------------------
ENUMERATION RULES (both are load-bearing)
--------------------------------------------------------------------------

1. The legacy v2 store is a sibling bucket literally named `cli`, and it also
   holds `sess_<uuid>.history` files -- so a `sess_` prefix alone does not
   mean v3. Only 16-hex bucket names are accepted, and every rejected bucket
   is REPORTED by name so that a renamed store shows up as a skip rather than
   silently reducing the denominator to zero.
2. A session directory's entry set is not asserted. `tool-outputs/` appears
   lazily, only once some tool returns a large payload, so "these exact
   entries exist" is a test that passes until it doesn't.

Every count printed carries its denominator, and every measurement over live
state carries the time it was taken. A zero with no denominator cannot
distinguish "absent" from "not instrumented".
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

# --------------------------------------------------------------------------
# Shapes
# --------------------------------------------------------------------------

BUCKET_RE = re.compile(r"^[0-9a-f]{16}$")
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
SESSION_RE = re.compile(r"^sess_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")

V2_BUCKET = "cli"
ROOT = "_root_"
ROW_KEYS = frozenset(("id", "payload", "timestamp"))
DISPATCH = "sub_agent_start"
COMPLETE = "sub_agent_complete"

RUN_SCHEMA = "kiro-mode-f/run/1"
TERMINAL_KINDS = ("abandoned", "done", "failed")
WORK_KINDS = ("implement", "verify")
EVENT_KINDS = ("claim", "propose", "release") + TERMINAL_KINDS + WORK_KINDS
LEGAL_TERMINATION = ("budget-exhausted", "no-progress-guard", "queue-drained")
MAX_ATTEMPTS = 3

PASS = "PASS"
FAIL = "FAIL"
INCONCLUSIVE = "INCONCLUSIVE"

# Worst-first, so an overall verdict is just max() over this ordering.
SEVERITY = {PASS: 0, INCONCLUSIVE: 1, FAIL: 2}


def now_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


@dataclass
class Check:
    """One predicate's outcome, with the denominator it was measured over."""

    id: str
    title: str
    verdict: str
    denominator: str
    detail: list = field(default_factory=list)

    def render(self) -> str:
        head = f"[{self.verdict:12}] {self.id}  {self.title}"
        lines = [head, f"{'':16}denominator: {self.denominator}"]
        lines.extend(f"{'':16}- {d}" for d in self.detail)
        return "\n".join(lines)


def overall(checks) -> str:
    if not checks:
        # No checks at all is not a pass. It is the shape a broken harness has.
        return INCONCLUSIVE
    return max((c.verdict for c in checks), key=lambda v: SEVERITY[v])


EXIT = {PASS: 0, FAIL: 1, INCONCLUSIVE: 2}


# --------------------------------------------------------------------------
# Transcript reading
# --------------------------------------------------------------------------


@dataclass
class ReadStats:
    """Denominators for the reconstruction itself."""

    files: int = 0
    empty_files: int = 0
    rows: int = 0
    rows_bad_keys: int = 0
    rows_embedded_newline: int = 0
    rows_splitlines_hazard: int = 0
    rows_unparseable: int = 0


_DECODER = json.JSONDecoder()
_WHITESPACE = " \t\r\n"

# Characters `str.splitlines()` breaks on that are NOT "\n". Splitting a
# transcript with `text.splitlines()` therefore cuts a perfectly valid record
# in half whenever its content happens to contain one of these, which is how
# the count below was discovered -- as a phantom parse failure.
SPLITLINES_ONLY = "\x0b\x0c\x1c\x1d\x1e\x85\u2028\u2029"


def read_rows(path: Path, stats: ReadStats):
    """Yield each row's payload, parsing by VALUE rather than by line.

    WHY NOT `for line in text.splitlines()`: because `str.splitlines()` breaks
    on far more than "\\n" -- it also breaks on U+0085 NEL, U+2028, U+2029,
    \\x0b, \\x0c and \\x1c-\\x1e. Transcript rows quote raw tool output, and
    tool output contains those bytes. Measured over this machine's corpus on
    2026-07-30: **2 of 88005 records contain U+0085**, both inside a string in
    a `tool_result` row, and one of them is a single 4.7 MB record. A
    `splitlines()` reader cuts each of those into 23 fragments, so it drops 2
    real records and reports 44 parse failures that do not exist. That was my
    first reading of this corpus and it was wrong; the engine is not at fault.

    Corrected by the same census: **0 of 88005 records span a real newline**,
    so the engine does honour one-record-per-line, and `for line in file`
    (which splits only on "\\n") would in fact have been safe. `raw_decode`
    over the whole text is safe under BOTH failure modes and matches `jq`'s row
    count exactly, which is the independent corroboration.

    The decoder is deliberately the STRICT default: 0 of 88005 records need
    `strict=False`, so a strict failure here is a finding to look at, not a
    tolerance to widen. Both hazard classes are counted rather than merely
    survived -- an invisible tolerance is how a wrong count looks right.

    On a decode error the reader resyncs at the next newline and counts the
    segment. The corpus is LIVE -- a transcript can be mid-append -- so a
    trailing partial record is expected rather than exceptional; counting the
    casualties beats crashing, and beats skipping them without a tally.
    """
    stats.files += 1
    raw = path.read_bytes()
    if not raw:
        stats.empty_files += 1
        return
    text = raw.decode("utf-8", errors="replace")
    n = len(text)
    i = 0
    while i < n:
        while i < n and text[i] in _WHITESPACE:
            i += 1
        if i >= n:
            break
        try:
            row, j = _DECODER.raw_decode(text, i)
        except ValueError:
            stats.rows_unparseable += 1
            nl = text.find("\n", i)
            if nl == -1:
                break
            i = nl + 1
            continue
        stats.rows += 1
        segment = text[i:j]
        if "\n" in segment:
            stats.rows_embedded_newline += 1
        if any(c in segment for c in SPLITLINES_ONLY):
            stats.rows_splitlines_hazard += 1
        i = j
        if not isinstance(row, dict) or frozenset(row) != ROW_KEYS:
            stats.rows_bad_keys += 1
        payload = row.get("payload") if isinstance(row, dict) else None
        if isinstance(payload, dict):
            yield payload


def count_rows_by_splitlines(path: Path) -> tuple:
    """The naive reader, kept as a CONTROL rather than as a comment.

    Returns (parsed, failed). Its disagreement with `read_rows` is the whole
    evidence that the streaming reader is doing something; a comment claiming
    so would rot.
    """
    parsed = failed = 0
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            json.loads(line)
        except ValueError:
            failed += 1
        else:
            parsed += 1
    return parsed, failed


# --------------------------------------------------------------------------
# Reconstruction
# --------------------------------------------------------------------------


@dataclass
class Session:
    """One v3 session's reconstructed execution forest."""

    path: Path
    edges: set = field(default_factory=set)  # (dispatcher, child)
    naive_edges: set = field(default_factory=set)  # (parentExecutionId, child)
    transcripts: set = field(default_factory=set)  # child ids with a file
    dispatches: int = 0
    completes: int = 0
    non_uuid_children: set = field(default_factory=set)

    @property
    def children(self) -> set:
        return {c for _, c in self.edges}

    @property
    def dispatched(self) -> bool:
        return bool(self.edges) or bool(self.transcripts)

    def orphan_transcripts(self) -> set:
        """A transcript on disk that no dispatch row names.

        A worker ran and nothing recorded that it was asked to.
        """
        return self.transcripts - self.children

    def missing_transcripts(self) -> set:
        """A dispatch row naming a child that never wrote a transcript.

        This is the on-disk signature of a dropped dispatch.
        """
        return self.children - self.transcripts

    def multi_parent(self) -> dict:
        by_child = defaultdict(set)
        for parent, child in self.edges:
            by_child[child].add(parent)
        return {c: p for c, p in by_child.items() if len(p) > 1}


def forest_depths(edges):
    """Depth of every node reachable from ROOT, plus the unreachable set.

    Direct children of the root session are depth 1. Returns
    (depths, unreachable). Unreachable nodes are either cycle members or
    children of a node that is itself no one's child -- both are findings, not
    crashes, so they come back as data.
    """
    kids = defaultdict(list)
    for parent, child in edges:
        kids[parent].append(child)
    depths = {}
    # A list plus a cursor keeps breadth-first order with no extra data
    # structure, and leaves the whole frontier readable after the walk.
    frontier = [(ROOT, 0)]
    cursor = 0
    while cursor < len(frontier):
        node, depth = frontier[cursor]
        cursor += 1
        for child in kids.get(node, ()):
            if child in depths:
                continue  # already placed; a second parent is reported elsewhere
            depths[child] = depth + 1
            frontier.append((child, depth + 1))
    all_nodes = {c for _, c in edges}
    return depths, all_nodes - set(depths)


def naive_forest_depths(edges):
    """Depths under the WRONG rule, for use as a control.

    Anything that is not itself somebody's child is treated as a root. On real
    data this returns max depth 1 for every session, which is the whole point:
    it reproduces the display's collapse.
    """
    children = {c for _, c in edges}
    parents = {p for p, _ in edges}
    kids = defaultdict(list)
    for parent, child in edges:
        kids[parent].append(child)
    depths = {}
    frontier = [(r, 0) for r in sorted(parents - children)]
    cursor = 0
    while cursor < len(frontier):
        node, depth = frontier[cursor]
        cursor += 1
        for child in kids.get(node, ()):
            if child in depths:
                continue
            depths[child] = depth + 1
            frontier.append((child, depth + 1))
    return depths, children - set(depths)


def scan_session(session_dir: Path, stats: ReadStats) -> Session:
    """Rebuild one session's forest. Entry set is deliberately not asserted."""
    sess = Session(path=session_dir)

    def absorb(payload, container):
        kind = payload.get("type")
        if kind == DISPATCH:
            child = payload.get("subSessionId")
            if not isinstance(child, str) or not child:
                return
            sess.dispatches += 1
            sess.edges.add((container, child))
            sess.naive_edges.add((payload.get("parentExecutionId") or ROOT, child))
            if not UUID_RE.match(child):
                sess.non_uuid_children.add(child)
        elif kind == COMPLETE:
            sess.completes += 1

    root_transcript = session_dir / "messages.jsonl"
    if root_transcript.is_file():
        for payload in read_rows(root_transcript, stats):
            absorb(payload, ROOT)

    subs = session_dir / "sub-executions"
    if subs.is_dir():
        for child_file in sorted(subs.glob("*.jsonl")):
            child_id = child_file.name[: -len(".jsonl")]
            sess.transcripts.add(child_id)
            for payload in read_rows(child_file, stats):
                absorb(payload, child_id)

    return sess


@dataclass
class Corpus:
    """Every session under one sessions root, plus the skips, by name."""

    root: Path
    stamped_at: str
    sessions: list = field(default_factory=list)
    stats: ReadStats = field(default_factory=ReadStats)
    skipped_buckets: list = field(default_factory=list)
    skipped_session_dirs: list = field(default_factory=list)


def scan_corpus(sessions_root: Path) -> Corpus:
    corpus = Corpus(root=sessions_root, stamped_at=now_stamp())
    if not sessions_root.is_dir():
        raise SystemExit(f"no sessions root at {sessions_root}")
    for bucket in sorted(sessions_root.iterdir()):
        if not bucket.is_dir():
            continue
        if not BUCKET_RE.match(bucket.name):
            why = "legacy v2 store" if bucket.name == V2_BUCKET else "not a 16-hex bucket"
            corpus.skipped_buckets.append(f"{bucket.name} ({why})")
            continue
        for session_dir in sorted(bucket.iterdir()):
            if not session_dir.is_dir():
                continue
            if not SESSION_RE.match(session_dir.name):
                corpus.skipped_session_dirs.append(f"{bucket.name}/{session_dir.name}")
                continue
            corpus.sessions.append(scan_session(session_dir, corpus.stats))
    return corpus


def corpus_report(corpus: Corpus) -> dict:
    """Aggregate census. Every field is paired with what it is out of."""
    dispatching = [s for s in corpus.sessions if s.dispatched]
    edges = Counter()
    depth_hist = Counter()
    naive_depth_hist = Counter()
    orphans, missing, multi, unreachable, non_uuid = [], [], [], [], []

    for sess in dispatching:
        for parent, _ in sess.edges:
            edges["from-root" if parent == ROOT else "from-a-sub"] += 1
        depths, stray = forest_depths(sess.edges)
        for d in depths.values():
            depth_hist[d] += 1
        naive_depths, _ = naive_forest_depths(sess.naive_edges)
        for d in naive_depths.values():
            naive_depth_hist[d] += 1
        label = f"{sess.path.parent.name}/{sess.path.name}"
        orphans += [f"{label}:{c}" for c in sorted(sess.orphan_transcripts())]
        missing += [f"{label}:{c}" for c in sorted(sess.missing_transcripts())]
        multi += [f"{label}:{c}" for c in sorted(sess.multi_parent())]
        unreachable += [f"{label}:{c}" for c in sorted(stray)]
        non_uuid += [f"{label}:{c}" for c in sorted(sess.non_uuid_children)]

    return {
        "depth_histogram": dict(sorted(depth_hist.items())),
        "dispatch_edges": dict(sorted(edges.items())),
        "missing_transcripts": missing,
        "multi_parent_children": multi,
        "naive_depth_histogram": dict(sorted(naive_depth_hist.items())),
        "non_uuid_child_ids": non_uuid,
        "orphan_transcripts": orphans,
        "read": vars(corpus.stats),
        "sessions_dispatching": len(dispatching),
        "sessions_scanned": len(corpus.sessions),
        "skipped_buckets": corpus.skipped_buckets,
        "skipped_session_dirs": corpus.skipped_session_dirs,
        "stamped_at": corpus.stamped_at,
        "sub_agent_complete_rows": sum(s.completes for s in dispatching),
        "sub_agent_start_rows": sum(s.dispatches for s in dispatching),
        "transcripts_on_disk": sum(len(s.transcripts) for s in dispatching),
        "unreachable_from_root": unreachable,
    }


def print_corpus_report(rep: dict, root: Path) -> None:
    out = sys.stdout.write
    out(f"sessions root      : {root}\n")
    out(f"stamped at         : {rep['stamped_at']}  (live corpus; re-measure, never hardcode)\n")
    out(f"buckets skipped    : {', '.join(rep['skipped_buckets']) or '(none)'}\n")
    out(f"session dirs skipped: {', '.join(rep['skipped_session_dirs']) or '(none)'}\n")
    r = rep["read"]
    out(
        f"transcripts read   : {r['files']} file(s), {r['empty_files']} empty, "
        f"{r['rows']} row(s)\n"
    )
    out(
        f"  rows off-shape   : {r['rows_bad_keys']} not exactly {{id,payload,timestamp}}, "
        f"{r['rows_unparseable']} unparseable\n"
    )
    out(
        f"  reader hazards   : {r['rows_embedded_newline']} row(s) embed a real newline "
        f"(breaks a per-line reader), {r['rows_splitlines_hazard']} row(s) embed a "
        "str.splitlines() splitter such as U+0085 (breaks a splitlines reader)\n"
    )
    out(f"sessions scanned   : {rep['sessions_scanned']}\n")
    out(f"  of those, dispatched: {rep['sessions_dispatching']}\n")
    out(f"sub_agent_start rows : {rep['sub_agent_start_rows']}\n")
    out(f"sub_agent_complete   : {rep['sub_agent_complete_rows']}\n")
    out(f"transcripts on disk  : {rep['transcripts_on_disk']}\n")
    out("dispatch edges by dispatcher kind:\n")
    for kind, count in rep["dispatch_edges"].items():
        out(f"  {kind:12} {count}\n")

    out("\nCORRECT method (edge = which file the dispatch row lives in)\n")
    hist = rep["depth_histogram"]
    for depth, count in hist.items():
        out(f"  depth {depth}: {count} execution(s)\n")
    out(f"  max depth reached: {max(hist) if hist else 0}\n")

    out("\nNAIVE method (edge = payload.parentExecutionId) -- CONTROL, expected to flatten\n")
    naive = rep["naive_depth_histogram"]
    for depth, count in naive.items():
        out(f"  depth {depth}: {count} execution(s)\n")
    out(f"  max depth reached: {max(naive) if naive else 0}\n")

    out("\nanomalies (each is a count over the corpus above, not a bare zero)\n")
    for key in (
        "missing_transcripts",
        "multi_parent_children",
        "non_uuid_child_ids",
        "orphan_transcripts",
        "unreachable_from_root",
    ):
        items = rep[key]
        out(f"  {key:24} {len(items)}")
        out(f"  {items}\n" if items else "\n")


def check_corpus(rep: dict):
    """Predicates the reconstruction itself must satisfy to be trusted."""
    checks = []
    denom = f"{rep['sessions_dispatching']} dispatching session(s), {rep['read']['rows']} row(s)"

    if rep["sessions_dispatching"] == 0 or rep["sub_agent_start_rows"] == 0:
        checks.append(
            Check(
                "C0",
                "the corpus contains dispatch rows at all",
                INCONCLUSIVE,
                denom,
                ["no dispatch found -- every downstream zero here is vacuous"],
            )
        )
        return checks
    checks.append(
        Check(
            "C0",
            "the corpus contains dispatch rows at all",
            PASS,
            denom,
            [f"{rep['sub_agent_start_rows']} dispatch row(s) parsed"],
        )
    )

    bad = rep["read"]["rows_bad_keys"] + rep["read"]["rows_unparseable"]
    checks.append(
        Check(
            "C1",
            "every transcript row is exactly {id, payload, timestamp}",
            PASS if bad == 0 else FAIL,
            f"{rep['read']['rows']} row(s)",
            [
                f"{rep['read']['rows_bad_keys']} row(s) off-shape, "
                f"{rep['read']['rows_unparseable']} segment(s) unparseable",
                f"{rep['read']['rows_embedded_newline']} row(s) embed a real newline; "
                f"{rep['read']['rows_splitlines_hazard']} embed a str.splitlines() splitter "
                "-- the second class is what a splitlines reader loses without saying so",
            ],
        )
    )

    orphans = rep["orphan_transcripts"]
    checks.append(
        Check(
            "C2",
            "no transcript exists that no dispatch row names",
            PASS if not orphans else FAIL,
            f"{rep['transcripts_on_disk']} transcript(s) on disk",
            [f"{len(orphans)} orphan(s)"] + orphans[:10],
        )
    )

    multi = rep["multi_parent_children"]
    checks.append(
        Check(
            "C3",
            "no execution is claimed by two dispatchers",
            PASS if not multi else FAIL,
            f"{rep['sub_agent_start_rows']} dispatch row(s)",
            [f"{len(multi)} child(ren) with more than one parent"] + multi[:10],
        )
    )

    stray = rep["unreachable_from_root"]
    checks.append(
        Check(
            "C4",
            "every execution is reachable from the root session (no cycles)",
            PASS if not stray else FAIL,
            f"{sum(rep['depth_histogram'].values())} placed execution(s)",
            [f"{len(stray)} unreachable"] + stray[:10],
        )
    )

    # The control that keeps the reconstruction honest. If the naive method
    # ever matches the correct one on a corpus that HAS nesting, then either
    # parentExecutionId changed meaning (good news, verify it) or the correct
    # method silently regressed to the naive one (bad news, and otherwise
    # invisible -- every count would still look right, only depth would lie).
    correct_max = max(rep["depth_histogram"], default=0)
    naive_max = max(rep["naive_depth_histogram"], default=0)
    nested = rep["dispatch_edges"].get("from-a-sub", 0)
    if nested == 0:
        verdict, note = (
            INCONCLUSIVE,
            "no nested dispatch in this corpus, so the two methods cannot disagree",
        )
    elif naive_max < correct_max:
        verdict, note = (
            PASS,
            f"naive flattens to depth {naive_max} where the correct method reaches "
            f"{correct_max} -- parentExecutionId is confirmed not to be the nesting edge",
        )
    else:
        verdict, note = (
            FAIL,
            f"naive depth {naive_max} >= correct depth {correct_max} with {nested} nested "
            "dispatch(es) present -- either parentExecutionId changed meaning or the "
            "reconstruction regressed to the naive rule",
        )
    checks.append(
        Check(
            "C5",
            "parentExecutionId flattens the forest (control on the edge rule)",
            verdict,
            f"{nested} nested dispatch row(s)",
            [note],
        )
    )
    return checks


# --------------------------------------------------------------------------
# Run-state predicates
# --------------------------------------------------------------------------

REQUIRED_RUN_KEYS = (
    "carriedForward",
    "events",
    "executions",
    "items",
    "notifications",
    "runId",
    "schema",
    "termination",
)


def load_run(path: Path):
    """Return (run, checks). A missing or shapeless state file IS a finding."""
    if not path.is_file():
        return None, [
            Check(
                "F3",
                "the run persists state across runs",
                FAIL,
                "1 declared state file",
                [f"no state file at {path} -- the loop has amnesia every run"],
            )
        ]
    try:
        run = json.loads(path.read_text(encoding="utf-8"))
    except ValueError as exc:
        return None, [
            Check(
                "F3",
                "the run persists state across runs",
                FAIL,
                "1 declared state file",
                [f"state file at {path} is not JSON: {exc}"],
            )
        ]
    missing = [k for k in REQUIRED_RUN_KEYS if k not in run]
    if missing:
        return None, [
            Check(
                "F3",
                "the run persists state across runs",
                FAIL,
                f"{len(REQUIRED_RUN_KEYS)} required key(s)",
                [f"state file is missing {missing} -- cannot resume from it"],
            )
        ]
    if run.get("schema") != RUN_SCHEMA:
        return None, [
            Check(
                "F3",
                "the run persists state across runs",
                FAIL,
                "1 schema field",
                [f"schema is {run.get('schema')!r}, expected {RUN_SCHEMA!r}"],
            )
        ]
    return run, []


@dataclass
class Timeline:
    """Per-item event history plus the violations found while walking it."""

    events: dict = field(default_factory=lambda: defaultdict(list))
    attempts: Counter = field(default_factory=Counter)
    terminals: Counter = field(default_factory=Counter)
    atomicity: list = field(default_factory=list)
    ordering: list = field(default_factory=list)
    dangling: list = field(default_factory=list)
    proposed_at: dict = field(default_factory=dict)


def walk_events(run) -> Timeline:
    """Replay the event log per item and record every atomicity violation.

    The claim interval is the unit: a `claim` opens one, a `release` or a
    terminal closes it. Two implementations inside one interval, a second
    concurrent claim, or any event after a terminal are all the same bug --
    the claim was not atomic -- so they are collected together.
    """
    tl = Timeline()
    events = sorted(run["events"], key=lambda e: e["seq"])
    seqs = [e["seq"] for e in events]
    if len(set(seqs)) != len(seqs):
        dupes = sorted({s for s in seqs if seqs.count(s) > 1})
        tl.ordering.append(f"duplicate seq value(s) {dupes} -- the log has no total order")

    for ev in events:
        tl.events[ev["item"]].append(ev)

    for item, evs in tl.events.items():
        holder = None
        implemented_in_interval = 0
        terminal_seen = False
        for ev in evs:
            kind = ev["kind"]
            if kind not in EVENT_KINDS:
                tl.ordering.append(f"{item}: unknown event kind {kind!r}")
                continue
            if terminal_seen:
                tl.atomicity.append(
                    f"{item}: {kind!r} at seq {ev['seq']} occurs AFTER the item reached "
                    "a terminal state"
                )
                if kind in TERMINAL_KINDS:
                    tl.terminals[item] += 1
                continue
            if kind == "propose":
                tl.proposed_at[item] = ev["seq"]
            elif kind == "claim":
                if holder is not None:
                    tl.atomicity.append(
                        f"{item}: claimed at seq {ev['seq']} by {ev['execution']} while "
                        f"{holder} still holds the claim -- the claim is not atomic"
                    )
                holder = ev["execution"]
                implemented_in_interval = 0
                tl.attempts[item] += 1
            elif kind == "implement":
                if holder is None:
                    tl.atomicity.append(
                        f"{item}: implemented at seq {ev['seq']} with no claim held"
                    )
                elif ev["execution"] != holder:
                    tl.atomicity.append(
                        f"{item}: implemented at seq {ev['seq']} by {ev['execution']} but "
                        f"{holder} holds the claim"
                    )
                implemented_in_interval += 1
                if implemented_in_interval > 1:
                    tl.atomicity.append(
                        f"{item}: implemented {implemented_in_interval} times inside one "
                        f"claim interval (seq {ev['seq']}) -- the item was worked twice"
                    )
            elif kind == "verify":
                if holder is None:
                    tl.atomicity.append(f"{item}: verified at seq {ev['seq']} with no claim held")
            elif kind == "release":
                if holder is None:
                    tl.atomicity.append(f"{item}: released at seq {ev['seq']} with no claim held")
                holder = None
            else:  # terminal
                if holder is None:
                    tl.atomicity.append(
                        f"{item}: reached {kind!r} at seq {ev['seq']} with no claim held"
                    )
                holder = None
                terminal_seen = True
                tl.terminals[item] += 1
        if holder is not None:
            tl.dangling.append(f"{item}: claim by {holder} never released and never terminal")
    return tl


def check_run(run, tl: Timeline):
    """P1..P4 and F1..F4."""
    checks = []
    items = {i["id"]: i for i in run["items"]}
    carried = set(run["carriedForward"])
    reason = run["termination"].get("reason")
    intervened = bool(run["termination"].get("operatorIntervened"))
    residual_ok = reason in ("budget-exhausted", "no-progress-guard")

    # ---- P1: exactly once, nothing dropped -------------------------------
    dropped, twice, residual = [], [], []
    for item_id in sorted(items):
        n = tl.terminals[item_id]
        if n > 1:
            twice.append(f"{item_id}: {n} terminal events")
        elif n == 0:
            if item_id in carried and residual_ok:
                residual.append(item_id)
            elif item_id in carried:
                dropped.append(
                    f"{item_id}: carried forward, but the run declared "
                    f"reason={reason!r} -- nothing may be left over on that reason"
                )
            else:
                dropped.append(f"{item_id}: never reached a terminal state and not carried forward")
    if not items:
        checks.append(
            Check("P1", "every item reaches a terminal state exactly once", INCONCLUSIVE, "0 items", ["the run declared no items"])
        )
    else:
        checks.append(
            Check(
                "P1",
                "every item reaches a terminal state exactly once",
                PASS if not (dropped or twice) else FAIL,
                f"{len(items)} item(s)",
                [
                    f"{len(items) - len(residual) - len(dropped) - len(twice)} worked once, "
                    f"{len(residual)} legally residual, {len(dropped)} dropped, "
                    f"{len(twice)} terminal more than once"
                ]
                + dropped
                + twice,
            )
        )

    # ---- P2: late-proposed items are worked too ---------------------------
    late = [i for i in sorted(items) if items[i].get("origin") == "late"]
    claim_seqs = sorted(e["seq"] for evs in tl.events.values() for e in evs if e["kind"] == "claim")
    starved, unproposed = [], []
    for item_id in late:
        if item_id not in tl.proposed_at:
            unproposed.append(f"{item_id}: origin=late but no propose event -- provenance unknown")
            continue
        seq = tl.proposed_at[item_id]
        claimed = any(e["kind"] == "claim" for e in tl.events[item_id])
        kept_working = any(
            s > seq
            for other, evs in tl.events.items()
            if other != item_id
            for s in (e["seq"] for e in evs if e["kind"] == "claim")
        )
        if not claimed and kept_working:
            starved.append(
                f"{item_id}: proposed at seq {seq}, never claimed, yet the loop went on to "
                "claim other items -- a late arrival was starved"
            )
    late_terminal = [i for i in late if tl.terminals[i] >= 1]
    if not late:
        p2 = Check(
            "P2",
            "every late-proposed item is worked",
            INCONCLUSIVE,
            "0 late-proposed item(s)",
            ["this run never minted an item mid-flight, so the property is untested"],
        )
    elif starved or unproposed:
        p2 = Check(
            "P2",
            "every late-proposed item is worked",
            FAIL,
            f"{len(late)} late-proposed item(s)",
            starved + unproposed,
        )
    elif not late_terminal:
        p2 = Check(
            "P2",
            "every late-proposed item is worked",
            FAIL,
            f"{len(late)} late-proposed item(s)",
            ["not one late-proposed item reached a terminal state"],
        )
    else:
        p2 = Check(
            "P2",
            "every late-proposed item is worked",
            PASS,
            f"{len(late)} late-proposed item(s)",
            [f"{len(late_terminal)} of {len(late)} reached a terminal state, none starved"],
        )
    checks.append(p2)

    # ---- P3: legal, unattended termination --------------------------------
    p3 = []
    if intervened:
        p3.append("termination.operatorIntervened is true -- the run did not end on its own")
    if reason not in LEGAL_TERMINATION:
        p3.append(f"termination reason {reason!r} is not one of {list(LEGAL_TERMINATION)}")
    p3 += tl.dangling
    unknown_state = [
        i for i in sorted(items) if tl.terminals[i] == 0 and i not in carried
    ]
    p3 += [f"{i}: at exit the item is in no legal state -- not terminal, not carried" for i in unknown_state]
    checks.append(
        Check(
            "P3",
            "the run terminates unattended with every item in a legal state",
            PASS if not p3 else FAIL,
            f"{len(items)} item(s), reason={reason!r}",
            p3 or [f"ended on {reason!r} with {len(carried)} item(s) carried forward"],
        )
    )

    # ---- P4: no item worked twice -----------------------------------------
    total_claims = sum(tl.attempts.values())
    if total_claims == 0:
        p4 = Check(
            "P4",
            "no item is worked twice (the claim is atomic)",
            INCONCLUSIVE,
            "0 claim event(s)",
            ["nothing was ever claimed, so atomicity was not exercised"],
        )
    else:
        problems = tl.atomicity + tl.ordering
        p4 = Check(
            "P4",
            "no item is worked twice (the claim is atomic)",
            PASS if not problems else FAIL,
            f"{total_claims} claim event(s) over {len(tl.events)} item(s)",
            problems or ["every claim interval held exactly one implementation"],
        )
    checks.append(p4)

    # ---- F1: attempts without progress -----------------------------------
    stuck = [
        f"{i}: {tl.attempts[i]} claim(s), still no terminal state"
        for i in sorted(items)
        if tl.attempts[i] > MAX_ATTEMPTS and tl.terminals[i] == 0
    ]
    checks.append(
        Check(
            "F1",
            f"no item is attempted more than {MAX_ATTEMPTS} times without progress",
            PASS if not stuck else FAIL,
            f"{len(items)} item(s), {total_claims} claim event(s)",
            stuck or [f"worst item took {max(tl.attempts.values(), default=0)} attempt(s)"],
        )
    )

    # ---- F2: verifier separated from implementer -------------------------
    pairs, same = 0, []
    for item_id, evs in sorted(tl.events.items()):
        impl = {e["session"] for e in evs if e["kind"] == "implement"}
        ver = {e["session"] for e in evs if e["kind"] == "verify"}
        if not impl or not ver:
            continue
        pairs += 1
        shared = impl & ver
        if shared:
            same.append(f"{item_id}: verified in the implementing session(s) {sorted(shared)}")
    if pairs == 0:
        f2 = Check(
            "F2",
            "verification runs in a different session from implementation",
            INCONCLUSIVE,
            "0 item(s) with both an implement and a verify event",
            ["nothing was both implemented and verified, so separation was not exercised"],
        )
    else:
        f2 = Check(
            "F2",
            "verification runs in a different session from implementation",
            PASS if not same else FAIL,
            f"{pairs} item(s) implemented and verified",
            same or [f"all {pairs} verified outside the implementing session"],
        )
    checks.append(f2)

    # ---- F3: state survives the run --------------------------------------
    # Reaching here means the file loaded and carried the required keys. What
    # is left to check is that it is actually resumable rather than merely
    # well-formed: residual work must be named, or there must be none.
    if residual_ok and not carried and any(tl.terminals[i] == 0 for i in items):
        f3_detail = ["ended early with unfinished items but carriedForward is empty"]
        f3_verdict = FAIL
    else:
        f3_detail = [f"carriedForward names {len(carried)} item(s); runId={run['runId']!r}"]
        f3_verdict = PASS
    checks.append(
        Check("F3", "the run persists state across runs", f3_verdict, "1 state file", f3_detail)
    )

    # ---- F4: notifications are exceptional -------------------------------
    notify = run["notifications"]
    observed = int(notify.get("runsObserved", 0))
    noisy = int(notify.get("runsWithNotification", 0))
    if observed < 2:
        f4 = Check(
            "F4",
            "notifications do not fire on every run",
            INCONCLUSIVE,
            f"{observed} run(s) observed",
            ["fewer than two runs observed -- 'every run' is not yet measurable"],
        )
    elif noisy >= observed:
        f4 = Check(
            "F4",
            "notifications do not fire on every run",
            FAIL,
            f"{observed} run(s) observed",
            [f"{noisy} of {observed} runs notified -- notification carries no signal"],
        )
    else:
        f4 = Check(
            "F4",
            "notifications do not fire on every run",
            PASS,
            f"{observed} run(s) observed",
            [f"{noisy} of {observed} runs notified"],
        )
    checks.append(f4)

    return checks


def check_cross(run, session_dir):
    """X1: the queue's worker forest against the transcripts' worker forest."""
    declared = run["executions"]
    declared_edges = {(e.get("dispatchedBy") or ROOT, e["id"]) for e in declared}

    if session_dir is None:
        return [
            Check(
                "X1",
                "the lineage forest and the reconstructed call graph agree",
                INCONCLUSIVE,
                "0 session directories",
                ["no sessionDir on the run state and none passed -- cross-check not run"],
            )
        ]
    session_dir = Path(session_dir)
    if not session_dir.is_dir():
        return [
            Check(
                "X1",
                "the lineage forest and the reconstructed call graph agree",
                INCONCLUSIVE,
                "0 session directories",
                [f"sessionDir {session_dir} does not exist -- cross-check not run"],
            )
        ]

    stats = ReadStats()
    sess = scan_session(session_dir, stats)
    disk_edges = sess.edges
    if not disk_edges and not declared_edges:
        return [
            Check(
                "X1",
                "the lineage forest and the reconstructed call graph agree",
                INCONCLUSIVE,
                "0 edges on either side",
                ["both views are empty -- agreement here is vacuous"],
            )
        ]

    detail = []
    only_declared = sorted(declared_edges - disk_edges)
    only_disk = sorted(disk_edges - declared_edges)
    if only_declared:
        detail.append(
            f"{len(only_declared)} edge(s) the queue believes in that no dispatch row "
            f"records: {only_declared[:8]} -- either the work was dropped, or the queue "
            "recorded the wrong dispatcher"
        )
    if only_disk:
        detail.append(
            f"{len(only_disk)} edge(s) on disk the queue does not know about: "
            f"{only_disk[:8]} -- a worker ran untracked"
        )

    declared_depths, declared_stray = forest_depths(declared_edges)
    disk_depths, disk_stray = forest_depths(disk_edges)
    declared_max = max(declared_depths.values(), default=0)
    disk_max = max(disk_depths.values(), default=0)
    if declared_max != disk_max:
        detail.append(
            f"nesting depth disagrees: queue says {declared_max}, transcripts say {disk_max}"
        )
    if len(declared_depths) != len(disk_depths):
        detail.append(
            f"worker count disagrees: queue says {len(declared_depths)}, "
            f"transcripts say {len(disk_depths)}"
        )
    for stray, side in ((declared_stray, "queue"), (disk_stray, "transcripts")):
        if stray:
            detail.append(f"{side}: {len(stray)} worker(s) unreachable from the root session")

    missing = sess.missing_transcripts()
    if missing:
        detail.append(
            f"{len(missing)} dispatched child(ren) never wrote a transcript: {sorted(missing)[:8]}"
        )

    return [
        Check(
            "X1",
            "the lineage forest and the reconstructed call graph agree",
            PASS if not detail else FAIL,
            f"{len(declared_edges)} declared edge(s) vs {len(disk_edges)} on disk, "
            f"{stats.rows} transcript row(s)",
            detail
            or [
                f"{len(disk_depths)} worker(s), max depth {disk_max}, identical edge sets",
            ],
        )
    ]


# --------------------------------------------------------------------------
# Synthetic fixtures (self-test)
# --------------------------------------------------------------------------

TURN = "11111111-1111-4111-8111-111111111111"
SESS = "sess_22222222-2222-4222-8222-222222222222"
BUCKET = "0123456789abcdef"
EXEC = {
    "A": "aaaaaaaa-0000-4000-8000-000000000001",
    "A1": "aaaaaaaa-0000-4000-8000-000000000011",
    "A2": "aaaaaaaa-0000-4000-8000-000000000012",
    "B": "bbbbbbbb-0000-4000-8000-000000000002",
}
HAZARD_LABEL = "A2"
NEL = "\u0085"
# The tree the fixture builds: root dispatches A and B; A dispatches A1 and A2.
# Four workers, max depth 2. Faithfully, every dispatch row carries the SAME
# parentExecutionId (the root turn), which is what the engine really does --
# so the naive rule sees a flat fan of four and the control has teeth.
TREE = {ROOT: ["A", "B"], "A": ["A1", "A2"]}


def _row(seq, payload):
    return json.dumps(
        {
            "id": f"row-{seq}",
            "payload": payload,
            "timestamp": f"2026-07-29T00:00:{seq:02d}.000Z",
        }
    )


def _dispatch_payload(child_id: str) -> dict:
    """A dispatch row's payload, with the field set the real engine writes.

    `parentExecutionId` is always the ROOT turn id, never the immediate
    dispatcher -- that is what the engine does, and writing anything else here
    would make the flattening control pass for the wrong reason.
    """
    return {
        "explanation": "synthetic",
        "parentExecutionId": TURN,
        "prompt": "work",
        "subAgentName": "worker",
        "subSessionId": child_id,
        "type": DISPATCH,
    }


def _hazard_row(child_id: str) -> str:
    """A row quoting tool output that contains two raw U+0085 bytes.

    ensure_ascii=False keeps the byte RAW; escaped as \\u0085 it would be
    harmless and the control would prove nothing.
    """
    return json.dumps(
        {
            "id": "row-hazard",
            "payload": {
                "output": f"codepage table{NEL}row two{NEL}row three",
                "subExecutionId": child_id,
                "type": "tool_result",
            },
            "timestamp": "2026-07-29T00:01:00.000Z",
        },
        ensure_ascii=False,
    )


def refuse_if_under_real_kiro(target: Path) -> None:
    """The only write guard that matters here.

    Every write in this file funnels through the fixture writer, so one refusal
    at that choke point covers all of them. The guard lives here rather than
    only at the caller because the caller is the thing most likely to be
    copied into a new script -- and a fixture writer aimed at the operator's
    real session store would corrupt live state that nothing here can restore.
    """
    real = (Path.home() / ".kiro").resolve()
    resolved = target.resolve()
    if resolved == real or real in resolved.parents or resolved in real.parents:
        raise SystemExit(f"refusing to write fixtures at {target}: it touches {real}")


def _write_session(bucket: Path, name: str, root_dispatches, child_files, hazard_in=None) -> Path:
    """Write one v3 session. `child_files` maps a child id to what it dispatched."""
    session_dir = bucket / name
    refuse_if_under_real_kiro(session_dir)
    (session_dir / "sub-executions").mkdir(parents=True)
    session_dir.joinpath("session.json").write_text(
        json.dumps({"id": name, "workspacePaths": ["/nonexistent/synthetic"]}),
        encoding="utf-8",
    )
    rows = [_row(i + 1, _dispatch_payload(c)) for i, c in enumerate(root_dispatches)]
    session_dir.joinpath("messages.jsonl").write_text(
        "".join(r + "\n" for r in rows), encoding="utf-8"
    )
    for child_id, kids in child_files.items():
        crows = [_row(90, {"name": "fs_read", "subExecutionId": child_id, "type": "tool_call"})]
        if child_id == hazard_in:
            crows.append(_hazard_row(child_id))
        crows += [_row(91 + i, _dispatch_payload(k)) for i, k in enumerate(kids)]
        (session_dir / "sub-executions" / f"{child_id}.jsonl").write_text(
            "".join(r + "\n" for r in crows), encoding="utf-8"
        )
    return session_dir


def build_synthetic_sessions(root: Path) -> Path:
    """Write a synthetic v3 sessions root whose forest we know by hand."""
    session_dir = _write_session(
        root / BUCKET,
        SESS,
        [EXEC[label] for label in TREE[ROOT]],
        {EXEC[label]: [EXEC[k] for k in TREE.get(label, ())] for label in EXEC},
        hazard_in=EXEC[HAZARD_LABEL],
    )
    # A `cli` sibling bucket holding v2 files, so the enumeration rule that
    # excludes it is exercised rather than assumed.
    v2 = root / V2_BUCKET
    v2.mkdir()
    v2.joinpath("sess_33333333-3333-4333-8333-333333333333.history").write_text(
        "{}\n", encoding="utf-8"
    )
    return session_dir


BROKEN_BUCKET = "fedcba9876543210"
BROKEN_SESSIONS = {
    "cycle": "sess_66666666-6666-4666-8666-666666666666",
    "missing": "sess_77777777-7777-4777-8777-777777777777",
    "multi-parent": "sess_55555555-5555-4555-8555-555555555555",
    "orphan": "sess_44444444-4444-4444-8444-444444444444",
}
BROKEN_EXEC = {
    "cycle-p": "cccccccc-0000-4000-8000-00000000000a",
    "cycle-q": "cccccccc-0000-4000-8000-00000000000b",
    "multi-m": "dddddddd-0000-4000-8000-00000000000c",
    "multi-z": "dddddddd-0000-4000-8000-00000000000d",
    "never-wrote": "eeeeeeee-0000-4000-8000-00000000000f",
    "orphan-file": "ffffffff-0000-4000-8000-00000000000e",
    "orphan-real": "ffffffff-0000-4000-8000-00000000000d",
}


def build_broken_sessions(root: Path) -> Path:
    """A deliberately pathological corpus, one session per anomaly.

    Without this, C2/C3/C4 return PASS over a corpus that could not have
    tripped them -- a green result with an empty denominator. A mutation run
    caught exactly that: deleting C2's orphan detection outright left the
    self-test green until this fixture existed.
    """
    bucket = root / BROKEN_BUCKET
    # A transcript on disk that no dispatch row names.
    _write_session(
        bucket,
        BROKEN_SESSIONS["orphan"],
        [BROKEN_EXEC["orphan-real"]],
        {BROKEN_EXEC["orphan-real"]: [], BROKEN_EXEC["orphan-file"]: []},
    )
    # One child claimed by two dispatchers: the root AND another child.
    _write_session(
        bucket,
        BROKEN_SESSIONS["multi-parent"],
        [BROKEN_EXEC["multi-m"], BROKEN_EXEC["multi-z"]],
        {BROKEN_EXEC["multi-m"]: [BROKEN_EXEC["multi-z"]], BROKEN_EXEC["multi-z"]: []},
    )
    # Two children dispatching each other, neither dispatched from the root.
    _write_session(
        bucket,
        BROKEN_SESSIONS["cycle"],
        [],
        {
            BROKEN_EXEC["cycle-p"]: [BROKEN_EXEC["cycle-q"]],
            BROKEN_EXEC["cycle-q"]: [BROKEN_EXEC["cycle-p"]],
        },
    )
    # A dispatch whose child never wrote a transcript -- the on-disk signature
    # of a dropped dispatch, and a shape the REAL corpus exhibits once.
    _write_session(bucket, BROKEN_SESSIONS["missing"], [BROKEN_EXEC["never-wrote"]], {})
    return bucket


def good_run(session_dir: Path) -> dict:
    """A run with no violations AND no inconclusive checks.

    Every predicate needs a live denominator to return PASS, so the fixture
    has to exercise late proposal, verifier separation and a multi-run
    notification history. That is deliberate: if the happy path could go green
    with empty denominators, so could a broken one.
    """
    return {
        "carriedForward": [],
        "events": [
            {"execution": EXEC["A"], "item": "s1", "kind": "claim", "seq": 1, "session": "sess-a"},
            {"execution": EXEC["A"], "item": "s1", "kind": "implement", "seq": 2, "session": "sess-a"},
            {"execution": EXEC["A"], "item": "L1", "kind": "propose", "seq": 3, "session": "sess-a"},
            {"execution": EXEC["B"], "item": "s1", "kind": "verify", "seq": 4, "session": "sess-b"},
            {"execution": EXEC["A"], "item": "s1", "kind": "done", "seq": 5, "session": "sess-a"},
            {"execution": EXEC["B"], "item": "s2", "kind": "claim", "seq": 6, "session": "sess-b"},
            {"execution": EXEC["B"], "item": "s2", "kind": "implement", "seq": 7, "session": "sess-b"},
            {"execution": EXEC["A1"], "item": "s2", "kind": "verify", "seq": 8, "session": "sess-a1"},
            {"execution": EXEC["B"], "item": "s2", "kind": "done", "seq": 9, "session": "sess-b"},
            {"execution": EXEC["A1"], "item": "L1", "kind": "claim", "seq": 10, "session": "sess-a1"},
            {"execution": EXEC["A1"], "item": "L1", "kind": "implement", "seq": 11, "session": "sess-a1"},
            {"execution": EXEC["A2"], "item": "L1", "kind": "verify", "seq": 12, "session": "sess-a2"},
            {"execution": EXEC["A1"], "item": "L1", "kind": "done", "seq": 13, "session": "sess-a1"},
        ],
        "executions": [
            {"dispatchedBy": None, "id": EXEC["A"], "role": "implementer"},
            {"dispatchedBy": None, "id": EXEC["B"], "role": "verifier"},
            {"dispatchedBy": EXEC["A"], "id": EXEC["A1"], "role": "implementer"},
            {"dispatchedBy": EXEC["A"], "id": EXEC["A2"], "role": "verifier"},
        ],
        "items": [
            {"id": "L1", "origin": "late", "parent": "s1"},
            {"id": "s1", "origin": "seed", "parent": None},
            {"id": "s2", "origin": "seed", "parent": None},
        ],
        "notifications": {"runsObserved": 4, "runsWithNotification": 1, "thisRun": 0},
        "runId": "synthetic-good",
        "schema": RUN_SCHEMA,
        "sessionDir": str(session_dir),
        "stampedAt": now_stamp(),
        "termination": {"operatorIntervened": False, "reason": "queue-drained"},
    }


def _drop_item(run):
    """A seeded item that no worker ever touched and nothing carried."""
    run["items"].append({"id": "s3", "origin": "seed", "parent": None})


def _terminal_twice(run):
    run["events"].append(
        {"execution": EXEC["A"], "item": "s1", "kind": "done", "seq": 14, "session": "sess-a"}
    )


def _late_never_worked(run):
    run["events"] = [e for e in run["events"] if not (e["item"] == "L1" and e["kind"] != "propose")]
    run["carriedForward"] = ["L1"]
    run["termination"] = {"operatorIntervened": False, "reason": "budget-exhausted"}


def _operator_intervened(run):
    run["termination"] = {"operatorIntervened": True, "reason": "queue-drained"}


def _dangling_claim(run):
    run["events"] = [e for e in run["events"] if not (e["item"] == "s1" and e["kind"] == "done")]
    run["carriedForward"] = ["s1"]
    run["termination"] = {"operatorIntervened": False, "reason": "budget-exhausted"}


def _widen_seq(run):
    """Multiply every seq by 10 so an event can be INSERTED between two.

    Without this, an appended event lands after the item's terminal and trips
    claim-after-terminal instead -- which is also a P4 failure, so the case
    would still go green while testing something else entirely. That happened
    on the first draft of `_double_worked`.
    """
    for ev in run["events"]:
        ev["seq"] *= 10


def _double_worked(run):
    """s2 implemented twice inside ONE claim interval (claim 60 .. done 90)."""
    _widen_seq(run)
    run["events"].append(
        {"execution": EXEC["B"], "item": "s2", "kind": "implement", "seq": 65, "session": "sess-b"}
    )


def _double_claimed(run):
    """A second execution claims s2 while the first still holds the claim."""
    _widen_seq(run)
    run["events"] += [
        {"execution": EXEC["A"], "item": "s2", "kind": "claim", "seq": 65, "session": "sess-a"},
        {"execution": EXEC["A"], "item": "s2", "kind": "implement", "seq": 66, "session": "sess-a"},
    ]


def _claim_after_terminal(run):
    run["events"].append(
        {"execution": EXEC["B"], "item": "s1", "kind": "claim", "seq": 15, "session": "sess-b"}
    )


def _four_attempts(run):
    run["events"] = [e for e in run["events"] if e["item"] != "s2"]
    for n in range(4):
        run["events"] += [
            {
                "execution": EXEC["B"],
                "item": "s2",
                "kind": "claim",
                "seq": 60 + 2 * n,
                "session": "sess-b",
            },
            {
                "execution": EXEC["B"],
                "item": "s2",
                "kind": "release",
                "seq": 61 + 2 * n,
                "session": "sess-b",
            },
        ]
    run["carriedForward"] = ["s2"]
    run["termination"] = {"operatorIntervened": False, "reason": "no-progress-guard"}


def _verify_in_same_session(run):
    for ev in run["events"]:
        if ev["item"] == "s1" and ev["kind"] == "verify":
            ev["session"] = "sess-a"


def _drop_carried_forward_key(run):
    del run["carriedForward"]


def _notify_every_run(run):
    run["notifications"] = {"runsObserved": 4, "runsWithNotification": 4, "thisRun": 1}


def _cross_missing_worker(run):
    run["executions"] = [e for e in run["executions"] if e["id"] != EXEC["A2"]]


def _cross_phantom_worker(run):
    """The queue declares a worker that never wrote a transcript.

    This exercises the OTHER arm of the edge-set diff. `_cross_flattened`
    happens to trip both arms at once, which left this one uncovered until a
    mutation run deleted it and the self-test stayed green.
    """
    run["executions"].append(
        {"dispatchedBy": None, "id": "0badbad0-0000-4000-8000-000000000099", "role": "implementer"}
    )


def _cross_flattened(run):
    """The display's lie, written into the state file: A1 reads root-spawned."""
    for ex in run["executions"]:
        if ex["id"] == EXEC["A1"]:
            ex["dispatchedBy"] = None


def _no_late_items(run):
    run["items"] = [i for i in run["items"] if i["id"] != "L1"]
    run["events"] = [e for e in run["events"] if e["item"] != "L1"]


def _single_run_history(run):
    run["notifications"] = {"runsObserved": 1, "runsWithNotification": 1, "thisRun": 1}


# id -> (mutator, {check id: expected verdict}, {check id: required reason}).
#
# The third element is what stops a case from passing for the wrong reason: two
# distinct bugs can both land on P4, so the verdict alone does not prove the
# fixture exercised the bug it is named after. Every case that shares a check
# with another case carries a reason.
CASES = {
    "claim-after-terminal": (
        _claim_after_terminal,
        {"P4": FAIL},
        {"P4": "occurs AFTER the item reached a terminal state"},
    ),
    "cross-flattened": (
        _cross_flattened,
        {"X1": FAIL},
        {"X1": "a worker ran untracked"},
    ),
    "cross-missing-worker": (
        _cross_missing_worker,
        {"X1": FAIL},
        {"X1": "worker count disagrees"},
    ),
    "cross-phantom-worker": (
        _cross_phantom_worker,
        {"X1": FAIL},
        {"X1": "no dispatch row records"},
    ),
    "double-claimed": (
        _double_claimed,
        {"P4": FAIL},
        {"P4": "still holds the claim -- the claim is not atomic"},
    ),
    "double-worked": (
        _double_worked,
        {"P4": FAIL},
        {"P4": "inside one claim interval"},
    ),
    "dropped-item": (
        _drop_item,
        {"P1": FAIL},
        {"P1": "never reached a terminal state and not carried forward"},
    ),
    "four-attempts-no-progress": (
        _four_attempts,
        {"F1": FAIL, "P1": PASS},
        {"F1": "still no terminal state"},
    ),
    "late-never-worked": (
        _late_never_worked,
        {"P1": PASS, "P2": FAIL},
        {"P2": "a late arrival was starved"},
    ),
    "no-carried-forward-key": (
        _drop_carried_forward_key,
        {"F3": FAIL},
        {"F3": "cannot resume from it"},
    ),
    "no-late-items": (_no_late_items, {"P2": INCONCLUSIVE}, {"P2": "untested"}),
    "notify-every-run": (
        _notify_every_run,
        {"F4": FAIL},
        {"F4": "notification carries no signal"},
    ),
    "operator-intervened": (
        _operator_intervened,
        {"P3": FAIL},
        {"P3": "did not end on its own"},
    ),
    "single-run-history": (
        _single_run_history,
        {"F4": INCONCLUSIVE},
        {"F4": "not yet measurable"},
    ),
    "stranded-claim": (
        _dangling_claim,
        {"P1": PASS, "P3": FAIL},
        {"P3": "never released and never terminal"},
    ),
    "terminal-twice": (
        _terminal_twice,
        {"P1": FAIL},
        {"P1": "2 terminal events"},
    ),
    "verify-in-implementer-session": (
        _verify_in_same_session,
        {"F2": FAIL},
        {"F2": "verified in the implementing session"},
    ),
}


# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------


def evaluate(run_path: Path, session_override=None):
    run, checks = load_run(run_path)
    if run is None:
        return checks
    try:
        tl = walk_events(run)
        return check_run(run, tl) + check_cross(run, session_override or run.get("sessionDir"))
    except (KeyError, TypeError, ValueError) as exc:
        # A malformed run file must come back as a FAILED CHECK, not a
        # traceback. An operator reading a stack trace has to guess whether the
        # run was bad or the harness was; this says which, and keeps the exit
        # code meaningful.
        return [
            Check(
                "E0",
                "the run state can be evaluated at all",
                FAIL,
                f"1 state file ({run_path})",
                [f"{type(exc).__name__} while evaluating: {exc}"],
            )
        ]


def cmd_reconstruct(args) -> int:
    corpus = scan_corpus(Path(args.sessions_root))
    rep = corpus_report(corpus)
    if args.json:
        print(json.dumps(rep, indent=2, sort_keys=True))
    else:
        print_corpus_report(rep, corpus.root)
    checks = check_corpus(rep)
    print()
    for c in checks:
        print(c.render())
    verdict = overall(checks)
    print(f"\nreconstruction verdict: {verdict}")
    return EXIT[verdict]


def cmd_check(args) -> int:
    checks = evaluate(Path(args.run), args.session_dir)
    for c in checks:
        print(c.render())
    verdict = overall(checks)
    print(f"\nrun verdict: {verdict}")
    return EXIT[verdict]


def cmd_self_test(args) -> int:
    tmp = Path(tempfile.mkdtemp(prefix="kiro-mode-f-self-test-"))
    real = (Path.home() / ".kiro").resolve()
    if tmp.resolve() == real or real in tmp.resolve().parents:
        raise SystemExit(f"refusing: temp dir {tmp} is under {real}")

    asserted, failures = 0, []

    def expect(label, ok, note):
        """One assertion, counted. The count IS the denominator of the PASS."""
        nonlocal asserted
        asserted += 1
        print(f"[{'PASS' if ok else 'FAIL'}] {label}: {note}")
        if not ok:
            failures.append(label)
        return ok

    def expect_verdict(label, check, want):
        got = check.verdict if check else "MISSING"
        ok = expect(label, check is not None and check.verdict == want, f"{got} (want {want})")
        if check is not None and (not ok or (want == FAIL and args.verbose)):
            print(check.render())

    try:
        # --- the write guard, in both directions ---------------------------
        # An untested guard is a comment. The negative half matters as much as
        # the positive one: a guard that refuses everything also "passes".
        for label, target, should_refuse in (
            ("guard.refuses-real-store", Path.home() / ".kiro" / "sessions" / "x" / "y", True),
            ("guard.allows-temp-dir", tmp / "sessions" / "x" / "y", False),
        ):
            try:
                refuse_if_under_real_kiro(target)
            except SystemExit as exc:
                refused, note = True, str(exc)
            else:
                refused, note = False, "allowed"
            expect(label, refused == should_refuse, note)

        session_dir = build_synthetic_sessions(tmp / "sessions")

        # --- the reconstruction, over a forest known by hand ---------------
        corpus = scan_corpus(tmp / "sessions")
        rep = corpus_report(corpus)
        expected = {
            "depth_histogram": {1: 2, 2: 2},
            "dispatch_edges": {"from-a-sub": 2, "from-root": 2},
            "naive_depth_histogram": {1: 4},
            "sessions_dispatching": 1,
            "sessions_scanned": 1,
            "skipped_buckets": [f"{V2_BUCKET} (legacy v2 store)"],
            "sub_agent_start_rows": 4,
            "transcripts_on_disk": 4,
        }
        for key, want in sorted(expected.items()):
            expect(f"reconstruct.{key}", rep[key] == want, f"got {rep[key]}, want {want}")
        for c in check_corpus(rep):
            expect_verdict(f"reconstruct.{c.id}", c, PASS)

        # --- the splitlines control ----------------------------------------
        # The fixture plants one row containing raw U+0085, the shape found
        # twice in the real corpus. The streaming reader must recover it AND
        # the naive splitlines reader must lose it -- if the naive reader
        # coped, this control would be proving nothing.
        hazard = session_dir / "sub-executions" / f"{EXEC[HAZARD_LABEL]}.jsonl"
        hazard_stats = ReadStats()
        recovered = len(list(read_rows(hazard, hazard_stats)))
        naive_parsed, naive_failed = count_rows_by_splitlines(hazard)
        expect(
            "splitlines.streaming-recovers-both-rows",
            hazard_stats.rows == 2 and recovered == 2,
            f"rows={hazard_stats.rows} payloads={recovered}, want 2/2",
        )
        expect(
            "splitlines.hazard-is-counted",
            hazard_stats.rows_splitlines_hazard == 1,
            f"{hazard_stats.rows_splitlines_hazard} of {hazard_stats.rows} row(s) flagged, want 1",
        )
        expect(
            "splitlines.no-phantom-failures",
            hazard_stats.rows_unparseable == 0,
            f"{hazard_stats.rows_unparseable} unparseable, want 0",
        )
        expect(
            "splitlines.naive-reader-collapses",
            naive_parsed < hazard_stats.rows and naive_failed > 0,
            f"naive parsed={naive_parsed} failed={naive_failed} vs streaming rows={hazard_stats.rows}",
        )
        expect(
            "splitlines.corpus-level-count",
            rep["read"]["rows_splitlines_hazard"] == 1,
            f"{rep['read']['rows_splitlines_hazard']} of {rep['read']['rows']} row(s), want 1",
        )

        # --- the pathological corpus: C2/C3/C4 must actually be able to fail
        build_broken_sessions(tmp / "broken")
        broken_report = corpus_report(scan_corpus(tmp / "broken"))
        for key, want in sorted(
            {
                "missing_transcripts": 1,
                "multi_parent_children": 1,
                "orphan_transcripts": 1,
                "unreachable_from_root": 2,
            }.items()
        ):
            expect(
                f"broken-corpus.{key}",
                len(broken_report[key]) == want,
                f"{len(broken_report[key])} found ({broken_report[key]}), want {want}",
            )
        broken_checks = {c.id: c for c in check_corpus(broken_report)}
        for cid in ("C2", "C3", "C4"):
            expect_verdict(f"broken-corpus.{cid}", broken_checks.get(cid), FAIL)

        # --- the happy path MUST pass, or every failure below is vacuous ---
        base = good_run(session_dir)
        run_path = tmp / "run-good.json"
        run_path.write_text(json.dumps(base, indent=2, sort_keys=True), encoding="utf-8")
        for cid, c in sorted({c.id: c for c in evaluate(run_path)}.items()):
            expect_verdict(f"good-run.{cid}", c, PASS)

        # --- and each broken run must fail on the RIGHT predicate ----------
        # ... FOR THE RIGHT REASON. The verdict alone is not enough: several
        # distinct bugs land on P4, so a fixture can trip the check it names
        # while exercising a different defect entirely.
        for name, (mutate, expected_verdicts, reasons) in sorted(CASES.items()):
            run = json.loads(json.dumps(base))
            mutate(run)
            path = tmp / f"run-{name}.json"
            path.write_text(json.dumps(run, indent=2, sort_keys=True), encoding="utf-8")
            got = {c.id: c for c in evaluate(path)}
            for cid, want in sorted(expected_verdicts.items()):
                expect_verdict(f"{name}.{cid}", got.get(cid), want)
            for cid, needle in sorted(reasons.items()):
                have = got.get(cid)
                joined = " | ".join(have.detail) if have else ""
                expect(
                    f"{name}.{cid}.reason",
                    needle in joined,
                    f"{needle!r} in detail" if needle in joined else f"{needle!r} NOT in {joined!r}",
                )

        # --- a missing state file is its own case (no mutator can express it)
        got = {c.id: c for c in evaluate(tmp / "does-not-exist.json")}
        expect_verdict("missing-state-file.F3", got.get("F3"), FAIL)

        # --- the CLI path --------------------------------------------------
        # Everything above calls evaluate() directly, which leaves `check`'s
        # argument parsing and its exit-code mapping unexercised. A harness
        # that always exits 0 satisfies every gate it is ever wired into, so
        # all three codes are asserted through a real subprocess.
        for label, mutate, want_exit in (
            ("cli-fail", _drop_item, EXIT[FAIL]),
            ("cli-inconclusive", _no_late_items, EXIT[INCONCLUSIVE]),
            ("cli-pass", None, EXIT[PASS]),
        ):
            run = json.loads(json.dumps(base))
            if mutate is not None:
                mutate(run)
            path = tmp / f"{label}.json"
            path.write_text(json.dumps(run, indent=2, sort_keys=True), encoding="utf-8")
            proc = subprocess.run(
                [sys.executable, __file__, "check", str(path)],
                capture_output=True,
                text=True,
                check=False,
            )
            expect(
                f"{label}.exit-code",
                proc.returncode == want_exit,
                f"exit={proc.returncode}, want {want_exit}",
            )
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print()
    if failures:
        print(f"FAIL: {len(failures)} of {asserted} assertion(s) did not hold: {failures}")
        return 1
    print(f"PASS: all {asserted} assertion(s) held -- the good run passed every predicate,")
    print("      and each broken run failed on exactly the predicate that should trip it")
    return 0


# --------------------------------------------------------------------------
# Mutation run: does the self-test actually have teeth?
# --------------------------------------------------------------------------
#
# A self-test that cannot fail is decoration. Each entry below breaks ONE piece
# of predicate logic; `verify.py mutants` applies it to a copy of this file and
# demands that `self-test` then exits non-zero. A SURVIVING mutant means that
# logic is unverified -- which is not hypothetical: the first run of this table
# found C2's orphan detection and one arm of the X1 edge diff both deletable
# with the self-test still green, and both gained a fixture as a result.
#
# The table is excluded from its own uniqueness check by the marker comments
# below, because every needle is a verbatim quote of the code it targets and
# would otherwise match itself.

# MUTANT-TABLE-BEGIN
MUTANTS = {
    "attempt-cap": (
        "if tl.attempts[i] > MAX_ATTEMPTS and tl.terminals[i] == 0",
        "if False",
    ),
    "cross-check-missing-arm": (
        "    only_declared = sorted(declared_edges - disk_edges)",
        "    only_declared = []",
    ),
    "cross-check-untracked-arm": (
        "    only_disk = sorted(disk_edges - declared_edges)",
        "    only_disk = []",
    ),
    "dangling-claim": (
        """        if holder is not None:
            tl.dangling.append(f"{item}: claim by {holder} never released and never terminal")""",
        """        if False:
            pass""",
    ),
    "double-implement": ("                if implemented_in_interval > 1:", "                if False:"),
    "drop-detection": (
        'dropped.append(f"{item_id}: never reached a terminal state and not carried forward")',
        "pass",
    ),
    "edge-rule": ("absorb(payload, child_id)", "absorb(payload, ROOT)"),
    "fixture-write-guard": (
        "    if resolved == real or real in resolved.parents or resolved in real.parents:",
        "    if False:",
    ),
    "missing-transcripts": ("return self.children - self.transcripts", "return set()"),
    "multi-parent-detection": (
        "return {c: p for c, p in by_child.items() if len(p) > 1}",
        "return {}",
    ),
    "notification-denominator": ("    if observed < 2:", "    if False:"),
    "operator-intervention": ("    if intervened:", "    if False:"),
    "orphan-detection": ("return self.transcripts - self.children", "return set()"),
    "overlapping-claim": (
        """                if holder is not None:
                    tl.atomicity.append(
                        f"{item}: claimed at seq {ev['seq']} by {ev['execution']} while "
                        f"{holder} still holds the claim -- the claim is not atomic"
                    )""",
        """                if False:
                    pass""",
    ),
    "schema-required-keys": (
        "    missing = [k for k in REQUIRED_RUN_KEYS if k not in run]",
        "    missing = []",
    ),
    "splitlines-reader": (
        "            row, j = _DECODER.raw_decode(text, i)",
        """            _lim = min(
                (p for p in (text.find(c, i) for c in ("\\n",) + tuple(SPLITLINES_ONLY))
                 if p != -1),
                default=n,
            )
            row, j = _DECODER.raw_decode(text[:_lim], i)""",
    ),
    "starvation-detection": ("        if not claimed and kept_working:", "        if False:"),
    "terminal-twice": ("        if n > 1:", "        if n > 99:"),
    "unreachable-detection": ("return depths, all_nodes - set(depths)", "return depths, set()"),
    "v2-bucket-exclusion": ("if not BUCKET_RE.match(bucket.name):", "if False:"),
    "verifier-separation": ("        shared = impl & ver", "        shared = set()"),
}
# MUTANT-TABLE-END

_TABLE_BEGIN = re.compile(r"^# MUTANT-TABLE-BEGIN$", re.M)
_TABLE_END = re.compile(r"^# MUTANT-TABLE-END$", re.M)


def apply_mutation(source: str, old: str, new: str):
    """Replace `old` outside the mutant table. Returns (mutated, occurrences).

    Splitting the source around the table markers is what makes the uniqueness
    count meaningful: the table quotes the code verbatim, so a naive count
    would always see at least two matches and every mutation would be refused
    as ambiguous.
    """
    begin, end = _TABLE_BEGIN.search(source), _TABLE_END.search(source)
    if not begin or not end:
        raise SystemExit("mutant table markers are missing from this file")
    head, table, tail = source[: begin.start()], source[begin.start() : end.end()], source[end.end() :]
    occurrences = head.count(old) + tail.count(old)
    return head.replace(old, new) + table + tail.replace(old, new), occurrences


def cmd_mutants(args) -> int:
    source = Path(__file__).read_text(encoding="utf-8")
    tmp = Path(tempfile.mkdtemp(prefix="kiro-mode-f-mutants-"))
    survived, killed, broken = [], [], []
    try:
        for name, (old, new) in sorted(MUTANTS.items()):
            mutated, occurrences = apply_mutation(source, old, new)
            if occurrences != 1:
                broken.append(f"{name} ({occurrences} match(es), want exactly 1)")
                print(f"[BROKEN     ] {name}: needle matched {occurrences} time(s), not 1")
                continue
            path = tmp / f"mutant-{name}.py"
            path.write_text(mutated, encoding="utf-8")
            proc = subprocess.run(
                [sys.executable, str(path), "self-test"],
                capture_output=True,
                text=True,
                check=False,
            )
            tripped = [ln for ln in proc.stdout.splitlines() if ln.startswith("[FAIL]")]
            if proc.returncode == 0:
                survived.append(name)
                print(f"[SURVIVED   ] {name}: self-test still passed -- this logic is UNVERIFIED")
            else:
                killed.append(name)
                first = tripped[0] if tripped else "(crashed rather than asserting)"
                print(f"[killed     ] {name}: {first}")
                if args.verbose:
                    for ln in tripped:
                        print(f"{'':14}{ln}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    total = len(MUTANTS)
    print(f"\nmutants killed {len(killed)}, survived {len(survived)}, unusable {len(broken)}"
          f"  (denominator {total})")
    if not total:
        print("FAIL: the mutant table is empty -- nothing was proven")
        return 1
    if broken:
        print(f"FAIL: {len(broken)} needle(s) no longer match the code: {broken}")
        return 1
    if survived:
        print(f"FAIL: {len(survived)} mutant(s) survived: {survived}")
        return 1
    print("PASS: every mutation broke the self-test, so no predicate is decorative")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="cmd", required=True)

    default_root = os.path.join(os.path.expanduser("~"), ".kiro", "sessions")

    p = sub.add_parser("reconstruct", help="rebuild execution forests from transcripts")
    p.add_argument("--sessions-root", default=default_root)
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_reconstruct)

    p = sub.add_parser("check", help="evaluate EXPECT.md predicates against a run state file")
    p.add_argument("run")
    p.add_argument("--session-dir", default=None, help="override the run's sessionDir")
    p.set_defaults(func=cmd_check)

    p = sub.add_parser("self-test", help="run the predicates against synthetic runs")
    p.add_argument("--verbose", action="store_true")
    p.set_defaults(func=cmd_self_test)

    p = sub.add_parser("mutants", help="break each predicate and demand the self-test notices")
    p.add_argument("--verbose", action="store_true")
    p.set_defaults(func=cmd_mutants)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
