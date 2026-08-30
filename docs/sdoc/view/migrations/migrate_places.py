#!/usr/bin/env python3
# cspell:ignore uids unrelate
"""migrate_places -- MECH-VIEW-PLACE-MIGRATION, through the scribe.

One scripted pass over the semantic-layer tree (root NAR-SEMANTIC-LAYER in
docs/plans/strictdoc-tooling/) and the canon root (NAR-CANON in docs/spec/):

  1. PLACE on the five tabs, the sheet snapshot as a tab, the legend as a
     card, the type, topic and gap narratives as screens; short tab titles;
     the root's WIDGET becomes callout and its STATEMENT the banner.
  2. New Start cards under the root: strip over Topics, grid over the grid
     card under Types, the layer stack, list over Gaps, the source facts.
  3. Under Types: the grid card and the ladders card; the seven type cards
     move to docs/spec/ with their plan citations turned into inline links.
  4. Under Edges: the allowed-targets rows, the fingerprint ladder, and a
     section that mirrors the allowed-edges topic.
  5. The 145 topic rows rewritten to headline / reference line / source
     line; the legend rows given their by-line labels.
  6. The canon root NAR-CANON and its tabs in docs/spec/.
  7. Fresh export, every check, and the migration's own verification.

Every node write goes through `sdoc`. The only hand edits are the ones the
scribe has no flag for: a 0000000 PARENT_FP declaration (added or removed
alongside the Cites it backs), and the [DOCUMENT] TITLE line that follows a
node's TITLE. No hash is ever changed; nothing here is signed.

Re-runnable: every step checks the state it wants before writing.
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

# The worktree is four directories above docs/sdoc/view/migrations/.
ROOT = Path(__file__).resolve().parents[4]
# The v1 page's hand-authored sources (build/data.json, build/authored.py)
# and this script's working directory live outside the tree; name the
# directory holding them in MIGRATE_SCRATCH.
SCRATCH = Path(
    os.environ.get(
        "MIGRATE_SCRATCH",
        "/tmp/claude-1000/-home-caubut-Documents-projects-nix-agentic-tools/3dc654a0-2cd2-4447-a890-5bfe23555a4b/scratchpad",
    )
)
BUILD = SCRATCH / "build"
WORK = SCRATCH / "wf5" / "migration"
TMP = WORK / "tmp"
EXPORT = WORK / "export"
PLAN = ROOT / "docs/plans/strictdoc-tooling"
SPEC = ROOT / "docs/spec"
BIN = ROOT / ".devenv/profile/bin"
SDOC = BIN / "sdoc"
STRICTDOC = BIN / "strictdoc"
SCRIPTS = ROOT / "dev/scripts"
VIEW = ROOT / "docs/sdoc/view"

ENV = {k: v for k, v in os.environ.items() if k not in ("PYTHONPATH", "STRICTDOC_CACHE_DIR")}

sys.path.insert(0, str(SCRIPTS))
from sdoc_fp import PLACEHOLDER, build_uid_index, iter_nodes, load_index, parse_parent_fp  # noqa: E402

# --------------------------------------------------------------------------
# vocabulary
# --------------------------------------------------------------------------

P = "NAR-SEMANTIC-LAYER"
ROOT_UID = P
LEGEND_UID = f"{P}-LEGEND"
TYPES_UID = f"{P}-TYPES"
TOPICS_UID = f"{P}-TOPICS"
GAPS_UID = f"{P}-GAPS"
EDGES_UID = f"{P}-EDGES"
WORDS_UID = f"{P}-WORDS"
SHEET_UID = "MECH-SEMANTIC-LAYER-WHITEBOARD"
BRIEF_UID = "SLICE-SEMANTIC-LAYER-RENDER"
ALLOWED_EDGES_UID = f"{P}-ALLOWED-EDGES"

TABS = {  # uid -> short title
    TYPES_UID: "Types",
    TOPICS_UID: "Topics",
    GAPS_UID: "Gaps",
    EDGES_UID: "Edges",
    WORDS_UID: "Words",
}

TYPE_CARD = {
    "REQUIREMENT": f"{P}-TYPE-REQUIREMENT",
    "USE CASE": f"{P}-TYPE-USE-CASE",
    "MECHANISM": f"{P}-TYPE-MECHANISM",
    "EVIDENCE": f"{P}-TYPE-EVIDENCE",
    "DECISION": f"{P}-TYPE-DECISION",
    "NARRATIVE": f"{P}-TYPE-NARRATIVE",
    "WORK": f"{P}-TYPE-WORK",
}
TYPE_CARDS_IN_TAB_ORDER = [
    TYPE_CARD["REQUIREMENT"],
    TYPE_CARD["USE CASE"],
    TYPE_CARD["MECHANISM"],
    TYPE_CARD["EVIDENCE"],
    TYPE_CARD["DECISION"],
    TYPE_CARD["NARRATIVE"],
    TYPE_CARD["WORK"],
]
GAP_CARD = {
    1: f"{P}-GAP-IDENTITY-HAS-NO-CARRIER",
    2: f"{P}-GAP-GRAMMAR-CANNOT-SPELL-THE-VOCABULARY",
    3: f"{P}-GAP-MERGE-BOUNDARY-IS-NOT-A-JOINT",
    4: f"{P}-GAP-MEMBERSHIP-AND-COLLECTION-CONTRADICT",
    5: f"{P}-GAP-SEMANTICS-LIVE-IN-TOOLS-WITH-NO-OWNER",
}
SECTION_UID = {
    "NODE STRUCT": f"{P}-NODE-STRUCT",
    "ALLOWED EDGES": f"{P}-ALLOWED-EDGES",
    "PARENT/CHILD": f"{P}-PARENT-CHILD",
    "FILES AND RETENTION": f"{P}-FILES-AND-RETENTION",
    "LIFECYCLES": f"{P}-LIFECYCLES",
    "IDENTITY": f"{P}-IDENTITY",
    "DIRTY RIPPLE": f"{P}-DIRTY-RIPPLE",
    "GATES BEYOND THE FSM": f"{P}-GATES-BEYOND-THE-FSM",
    "ON-DISK MOVES": f"{P}-ON-DISK-MOVES",
    "PLANS IN REFS": f"{P}-PLANS-IN-REFS",
    "MULTI-STEP WORK": f"{P}-MULTI-STEP-WORK",
    "FLOWS": f"{P}-FLOWS",
    "UNPLACED": f"{P}-UNPLACED",
}

TERMS = [
    ("joint", "NAR-TERM-JOINT"),
    ("checkpoint", "NAR-TERM-CHECKPOINT"),
    ("scribe", "NAR-TERM-SCRIBE"),
    ("sdoc", "NAR-TERM-SDOC"),
    ("strictdoc", "NAR-TERM-STRICTDOC"),
    ("canon", "NAR-TERM-CANON"),
    ("beads", "NAR-TERM-BEADS"),
]

LEGEND_ROWS = [
    ("WORKS", "green", "stands as written under the current direction", "Note"),
    ("FALLS OUT", "slate", "dissolved; the direction replaces it with something already in the model", "Dissolved by"),
    ("UNADDRESSED", "amber", "the direction is silent on it", "Note"),
    ("OPEN", "blue", "an open decision owns it", "Owned by"),
    ("GAP", "red", "needed, and nobody has written it", "Note"),
    # the layer stack's HERE rung (v1 #14 shaded L3): a bracket word is legend
    # data wherever it appears, so the stack's one word is a legend row too
    ("HERE", "teal", "the layer this page is about", None),
]

# the new narratives, by UID
START_SOLID = f"{P}-START-SOLID"
START_KINDS = f"{P}-START-KINDS"
START_LAYERS = f"{P}-START-LAYERS"
START_GAPS = f"{P}-START-GAPS"
START_SOURCE = f"{P}-START-SOURCE"
TYPES_GRID = f"{P}-TYPES-GRID"
TYPES_LADDERS = f"{P}-TYPES-LADDERS"
EDGES_RULES = f"{P}-EDGES-RULES"
EDGES_FINGERPRINTS = f"{P}-EDGES-FINGERPRINTS"
EDGES_ON_THE_SHEET = f"{P}-EDGES-ON-THE-SHEET"

CANON = "NAR-CANON"
CANON_SYSTEMS = "NAR-CANON-SYSTEMS"
CANON_START_COUNTS = "NAR-CANON-START-COUNTS"
CANON_TYPES = "NAR-CANON-TYPES"
CANON_TYPES_GRID = "NAR-CANON-TYPES-GRID"
CANON_TYPES_LADDERS = "NAR-CANON-TYPES-LADDERS"
CANON_EDGES = "NAR-CANON-EDGES"
CANON_WORDS = "NAR-CANON-WORDS"
CANON_WHITEBOARDS = "NAR-CANON-WHITEBOARDS"

LINK_RE = re.compile(r"\[LINK: ([A-Z0-9-]+)\]")
BARE_UID_RE = re.compile(r"\b[A-Z][A-Z0-9]*(?:-[A-Z0-9]+)+\b")
BRACKET_RE = re.compile(r"^(?P<text>.*?)\s*\[(?P<word>[^\[\]:]+?)(?::\s*(?P<by>[^\[\]]*?))?\]\s*$", re.S)

LOG: list[str] = []
COUNTS: dict[str, int] = {}


def note(msg: str) -> None:
    print(msg)
    LOG.append(msg)


def bump(key: str, n: int = 1) -> None:
    COUNTS[key] = COUNTS.get(key, 0) + n


# --------------------------------------------------------------------------
# files and the scribe
# --------------------------------------------------------------------------


def uid_files() -> dict[str, Path]:
    out: dict[str, Path] = {}
    for p in list(ROOT.glob("docs/**/*.sdoc")) + list(ROOT.glob("packages/*/.sdoc/*.sdoc")):
        text = p.read_text()
        for m in re.finditer(r"^UID: (\S+)$", text, re.M):
            out[m.group(1)] = p
    return out


FILES = uid_files()


def refresh_files() -> None:
    FILES.clear()
    FILES.update(uid_files())


def path_of(uid: str) -> Path:
    if uid not in FILES:
        refresh_files()
    if uid not in FILES:
        raise SystemExit(f"unknown UID {uid}")
    return FILES[uid]


def rel(p: Path) -> str:
    return str(p.relative_to(ROOT))


def run(cmd: list[str], check: bool = True, **kw) -> subprocess.CompletedProcess:
    r = subprocess.run(cmd, cwd=ROOT, env=ENV, text=True, capture_output=True, **kw)
    if check and r.returncode != 0:
        print(r.stdout)
        print(r.stderr)
        raise SystemExit(f"command failed: {' '.join(str(c) for c in cmd)}")
    return r


def sdoc(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    return run([str(SDOC), *args], check=check)


def field_of(uid: str, name: str) -> str | None:
    """Read one single-line or multi-line field from the node's file."""
    text = path_of(uid).read_text()
    m = re.search(rf"^{name}: >>>\n(.*?)\n<<<$", text, re.S | re.M)
    if m:
        return m.group(1)
    m = re.search(rf"^{name}: (.*)$", text, re.M)
    return m.group(1) if m else None


def node_field(uid: str, name: str) -> str | None:
    """Like field_of but skips the [DOCUMENT] header's TITLE."""
    text = path_of(uid).read_text()
    body = text.split("\n[NARRATIVE]\n", 1)[1] if "\n[NARRATIVE]\n" in text else text
    m = re.search(rf"^{name}: >>>\n(.*?)\n<<<$", body, re.S | re.M)
    if m:
        return m.group(1)
    m = re.search(rf"^{name}: (.*)$", body, re.M)
    return m.group(1) if m else None


def relations_of(uid: str) -> list[tuple[str, str, str | None]]:
    """[(TYPE, VALUE, ROLE)] in file order."""
    text = path_of(uid).read_text()
    out = []
    block = text.split("\nRELATIONS:\n", 1)
    if len(block) < 2:
        return out
    for entry in re.split(r"\n(?=- TYPE: )", "\n" + block[1].strip()):
        entry = entry.strip()
        if not entry:
            continue
        t = re.search(r"TYPE: (\S+)", entry).group(1)
        v = re.search(r"VALUE: (.+)", entry).group(1).strip()
        r = re.search(r"ROLE: (\S+)", entry)
        out.append((t, v, r.group(1) if r else None))
    return out


def has_relation(uid: str, role: str, target: str) -> bool:
    return any(v == target and r == role for _t, v, r in relations_of(uid))


def relate(uid: str, role: str, target: str) -> None:
    if has_relation(uid, role, target):
        return
    sdoc("relate", uid, "--role", role, "--target", target)
    bump("relations added")


def unrelate(uid: str, role: str, target: str) -> None:
    if not has_relation(uid, role, target):
        return
    sdoc("unrelate", uid, "--role", role, "--target", target)
    bump("relations removed")


def set_fields(uid: str, **fields: str) -> None:
    """sdoc set, only for the fields that differ. Keys are flag names with
    underscores (place, widget, title, statement, tags)."""
    args: list[str] = []
    for k, v in fields.items():
        current = node_field(uid, k.upper())
        if k == "statement":
            if (current or "").rstrip("\n") == v.rstrip("\n"):
                continue
            f = TMP / f"{uid}.statement.md"
            f.write_text(v.rstrip("\n") + "\n")
            args += ["--statement", f"@{f}"]
        else:
            if current == v:
                continue
            args += [f"--{k.replace('_', '-')}", v]
    if not args:
        return
    sdoc("set", uid, *args)
    bump("fields set", len(args) // 2)
    if "title" in fields:
        set_document_title(uid, fields["title"])


def set_document_title(uid: str, title: str) -> None:
    """The scribe leaves the [DOCUMENT] TITLE alone; the convention is that
    it equals the node's TITLE, so follow it by hand."""
    p = path_of(uid)
    lines = p.read_text().split("\n")
    assert lines[0] == "[DOCUMENT]", p
    assert lines[1].startswith("TITLE: "), p
    if lines[1] != f"TITLE: {title}":
        lines[1] = f"TITLE: {title}"
        p.write_text("\n".join(lines))
        bump("document titles followed")


def read_fp(uid: str) -> list[tuple[str, str]]:
    return list(parse_parent_fp(node_field(uid, "PARENT_FP")))


def write_fp(uid: str, entries: list[tuple[str, str]]) -> None:
    """Rewrite the PARENT_FP field: after RATIONALE if present, else after
    STATEMENT; before NOTES and RELATIONS. Removed when empty."""
    p = path_of(uid)
    text = p.read_text()
    text = re.sub(r"^PARENT_FP: >>>\n.*?\n<<<\n", "", text, count=1, flags=re.S | re.M)
    text = re.sub(r"^PARENT_FP: .*\n", "", text, count=1, flags=re.M)
    lines = text.split("\n")
    if entries:
        entries = sorted(entries)
        if len(entries) == 1:
            ins = [f"PARENT_FP: {entries[0][0]}:{entries[0][1]}"]
        else:
            ins = ["PARENT_FP: >>>"] + [f"{u}:{h}" for u, h in entries] + ["<<<"]
        anchor = "RATIONALE: >>>" if "RATIONALE: >>>" in lines else "STATEMENT: >>>"
        i = lines.index(anchor)
        j = next(k for k in range(i + 1, len(lines)) if lines[k] == "<<<")
        lines[j + 1 : j + 1] = ins
    p.write_text("\n".join(lines))


def declare_fp(uid: str, parents: list[str]) -> None:
    """Add a 0000000 declaration per parent that has none. Never touches an
    existing entry."""
    have = read_fp(uid)
    known = {u for u, _ in have}
    new = [(u, PLACEHOLDER) for u in parents if u not in known]
    if not new:
        return
    write_fp(uid, have + new)
    bump("fingerprint declarations added", len(new))


def retract_fp(uid: str, parents: list[str]) -> None:
    """Remove the declarations for parents no longer cited. Refuses to
    remove anything but a placeholder."""
    have = read_fp(uid)
    keep, gone = [], []
    for u, h in have:
        if u in parents:
            assert h == PLACEHOLDER, f"{uid}: {u} carries a hash, not a placeholder; refusing"
            gone.append(u)
        else:
            keep.append((u, h))
    if not gone:
        return
    write_fp(uid, keep)
    bump("fingerprint declarations removed", len(gone))


def term_uses(text: str) -> list[str]:
    scrub = BARE_UID_RE.sub(" ", LINK_RE.sub(" ", text))
    return [u for w, u in TERMS if re.search(rf"\b{w}s?\b", scrub, re.IGNORECASE)]


def citable_from(dirpath: Path, uid: str) -> bool:
    """INV-NO-EXTERNAL-PLAN-REFS: a node may cite its own plan, the spec and
    settled package architecture. The spec may cite the spec only."""
    s = rel(path_of(uid))
    if dirpath == SPEC:
        return s.startswith("docs/spec/")
    return s.startswith(rel(dirpath) + "/") or s.startswith("docs/spec/") or (s.startswith("packages/") and "/.sdoc/" in s)


def cites_for(statement: str, dirpath: Path) -> list[str]:
    seen: list[str] = []
    for u in LINK_RE.findall(statement):
        if u not in seen and citable_from(dirpath, u):
            seen.append(u)
    for u in term_uses(statement):
        if u not in seen:
            seen.append(u)
    return seen


def new_narrative(
    uid: str,
    title: str,
    widget: str,
    statement: str,
    *,
    dirpath: Path,
    place: str | None = None,
    tags: str | None = None,
    contains: list[str] = (),
    over: str | None = None,
    cites: list[str] | None = None,
) -> None:
    if cites is None:
        cites = cites_for(statement, dirpath)
    target = dirpath / f"{uid.lower()}.sdoc"
    if target.exists():
        # already written: make sure the fields match, then leave it
        set_fields(uid, title=title, widget=widget, statement=statement, **({"place": place} if place else {}), **({"tags": tags} if tags else {}))
        for c in cites:
            relate(uid, "Cites", c)
        declare_fp(uid, cites)
        return
    stmt = TMP / f"{uid}.statement.md"
    stmt.write_text(statement.rstrip("\n") + "\n")
    cmd = [
        "new", "NARRATIVE",
        "--uid", uid, "--title", title, "--depth", "sketch", "--widget", widget,
        "--statement", f"@{stmt}", "--path", rel(dirpath) + "/",
    ]
    if place:
        cmd += ["--place", place]
    if tags:
        cmd += ["--tags", tags]
    for c in contains:
        cmd += ["--relate", f"Contains={c}"]
    for c in cites:
        cmd += ["--relate", f"Cites={c}"]
    if over:
        cmd += ["--relate", f"Over={over}"]
    sdoc(*cmd)
    assert target.exists(), target
    FILES[uid] = target
    if cites:
        declare_fp(uid, cites)
    bump("narratives created")
    note(f"created {uid} ({widget}, {place or 'root'}) in {rel(dirpath)}: {len(contains)} contains, {len(cites)} cites{', over ' + over if over else ''}")


def contains_of(uid: str) -> list[str]:
    return [v for t, v, r in relations_of(uid) if t == "Child" and r == "Contains"]


def set_contains_order(uid: str, wanted: list[str]) -> None:
    """Unrelate what is not wanted; if the order already matches, stop;
    else unrelate everything and relate in order (relate appends)."""
    current = contains_of(uid)
    for c in current:
        if c not in wanted:
            unrelate(uid, "Contains", c)
    current = contains_of(uid)
    if current == wanted:
        return
    for c in current:
        unrelate(uid, "Contains", c)
    for c in wanted:
        relate(uid, "Contains", c)
    assert contains_of(uid) == wanted, (uid, contains_of(uid), wanted)
    note(f"{uid} Contains, in order: {len(wanted)}")


# --------------------------------------------------------------------------
# inputs
# --------------------------------------------------------------------------

spec = importlib.util.spec_from_file_location("authored", BUILD / "authored.py")
A = importlib.util.module_from_spec(spec)
spec.loader.exec_module(A)
DATA = json.loads((BUILD / "data.json").read_text())
SECTIONS = [s for s in DATA["sections"] if s["name"] in SECTION_UID]
assert [s["name"] for s in SECTIONS] == list(SECTION_UID)
assert sum(len(s["lines"]) for s in SECTIONS) == 145
HEAD_COMMIT = run(["git", "rev-parse", "--short", "HEAD"]).stdout.strip()


# --------------------------------------------------------------------------
# 1. places and titles on the existing tree
# --------------------------------------------------------------------------


def step_places() -> None:
    for uid, title in TABS.items():
        set_fields(uid, title=title, place="tab")
    set_fields(SHEET_UID, title="Sheet", place="tab")
    set_fields(LEGEND_UID, place="card")
    for uid in TYPE_CARD.values():
        set_fields(uid, place="screen")
    for uid in SECTION_UID.values():
        set_fields(uid, place="screen")
    for uid in GAP_CARD.values():
        set_fields(uid, place="screen")
    note("places set on 5 tabs, the sheet, the legend, 7 type cards, 13 topics, 5 gaps")

    legend_stmt = "Colour is only ever a tag, and every tag is written out beside it.\n\n" + "\n".join(
        f"- {w}: {c}: {m}" + (f": {by}" if by else "") for w, c, m, by in LEGEND_ROWS
    )
    set_fields(LEGEND_UID, statement=legend_stmt)

    banner = (
        "Nothing on this page is settled. It shows what the session of 2026-08-29 explored -- "
        "every semantic the canon describes, tagged against the direction of that day -- so the "
        "operator can decide what to settle. Decisions come afterwards, one at a time, and only "
        "for what they ask to settle."
    )
    set_fields(ROOT_UID, widget="callout", statement=banner)
    # the header chips v1 carried as its status pill (inventory #1)
    r = sdoc("set", ROOT_UID, "--tags", "explored, not settled", check=False)
    if r.returncode != 0:
        note(f"root TAGS 'explored, not settled' refused by the scribe: {r.stderr.strip()[:200]}")
    else:
        bump("fields set")


# --------------------------------------------------------------------------
# 3. the Types tab: grid card, ladders card, type cards to the spec
# --------------------------------------------------------------------------

GRID_ROWS = [
    "- normative: can be violated",
    "- descriptive: can only be wrong",
    "- universal: every case",
    "- particular: one case",
    f"- [LINK: {TYPE_CARD['REQUIREMENT']}]: normative: universal",
    f"- [LINK: {TYPE_CARD['DECISION']}]: normative: particular",
    f"- [LINK: {TYPE_CARD['MECHANISM']}]: descriptive: universal",
    f"- [LINK: {TYPE_CARD['EVIDENCE']}]: descriptive: particular",
    f"- [LINK: {TYPE_CARD['USE CASE']}]: outside",
    f"- [LINK: {TYPE_CARD['NARRATIVE']}]: outside",
    f"- [LINK: {TYPE_CARD['WORK']}]: outside",
]
GRID_INTRO = (
    "Two questions place a claim: does it say how the world ought to be or how it is, and is it "
    "about every case or one case. The decision sits inside the grid, the use case outside it as "
    "coverage, and the narrative and work outside it as representation and work "
    "([LINK: DEC-NODE-FAMILIES]). Tap a cell."
)
LADDER_ROWS = [
    "- DEPTH: design maturity; live counts from the export",
    "- AUTHORED_BY: llm, llm-accepted, llm-adopted, human: ruled to be four rungs",
    "- STATUS: open, accepted, rejected, superseded: on a decision",
]
LADDER_INTRO = "One ladder per state field, each rung with its live count over the selection."


def step_types() -> None:
    new_narrative(
        TYPES_GRID, "The grid", "grid", GRID_INTRO + "\n\n" + "\n".join(GRID_ROWS), dirpath=PLAN, place="card",
    )
    new_narrative(
        TYPES_LADDERS, "The state fields every type shares", "ladder", LADDER_INTRO + "\n\n" + "\n".join(LADDER_ROWS),
        dirpath=PLAN, place="card",
    )
    set_contains_order(TYPES_UID, [TYPES_GRID, TYPES_LADDERS] + TYPE_CARDS_IN_TAB_ORDER)

    # the type cards: plan citations become links, then the file moves
    for uid in TYPE_CARD.values():
        stmt = node_field(uid, "STATEMENT")
        plan_cites = [v for t, v, r in relations_of(uid) if r == "Cites" and rel(path_of(v)).startswith("docs/plans/")]
        for c in plan_cites:
            if f"[LINK: {c}]" not in stmt:
                stmt = stmt.rstrip("\n") + f"\n\nSee also [LINK: {c}]."
        if stmt != node_field(uid, "STATEMENT"):
            set_fields(uid, statement=stmt)
        for c in plan_cites:
            unrelate(uid, "Cites", c)
        retract_fp(uid, plan_cites)
        if rel(path_of(uid)).startswith("docs/plans/"):
            sdoc("move", uid, "--to", "docs/spec/")
            refresh_files()
            bump("type cards moved to the spec")
        if plan_cites:
            note(f"{uid}: {len(plan_cites)} plan citation(s) turned into links: {', '.join(plan_cites)}")
        assert rel(path_of(uid)) == f"docs/spec/{uid.lower()}.sdoc"


# --------------------------------------------------------------------------
# 2. the Start cards under the root
# --------------------------------------------------------------------------


def step_start() -> None:
    new_narrative(
        START_SOLID, "Where the design is solid, and where it is not", "strip",
        "Each row is one topic of the sheet. Bar length is how many lines the topic has; the "
        "segments are the tags. Tap a segment to see just those lines.",
        dirpath=PLAN, place="section", over=TOPICS_UID,
    )
    new_narrative(
        START_KINDS, "The seven kinds of node", "grid",
        "Ruled on 2026-08-28 and re-ruled on 2026-08-30: node types come from two questions -- does "
        "it say how the world ought to be or how it is, and is it about every case or one case. "
        "Tap a cell.",
        dirpath=PLAN, place="section", over=TYPES_GRID,
    )
    layers = "\n".join([
        "Each layer may use only what is beneath it.",
        "",
        "- L3: the semantic layer: lifecycles, gates, ripple, signing, readiness -- a language that decomposes into L1 plus L2 [HERE]",
        "- L2: hook machinery: where logic can attach and what a handler is handed; semantic-free",
        "- L1: this repo's grammar: which node types exist, their fields, their relation roles",
        "- L0: grammar machinery: the typed Nix options, the checks and the emitter that renders the grammar file",
        "",
        "The hard rule, [LINK: DEC-LAYER-STACK]: semantics are never written directly into a tool. "
        "This page is about L3 -- and much of it is currently sitting in L0 tools.",
    ])
    new_narrative(START_LAYERS, "The four layers", "stack", layers, dirpath=PLAN, place="section")
    new_narrative(
        START_GAPS, "The five top gaps", "list",
        "The sheet's own closing section -- the places where the direction has no answer at all. "
        "Each line carries how many rows feed the gap and how many nodes it touches.",
        dirpath=PLAN, place="section", over=GAPS_UID,
    )
    source = "\n".join([
        f"- input: [LINK: {SHEET_UID}]",
        f"- brief: [LINK: {BRIEF_UID}]",
        f"- canon: export at {HEAD_COMMIT}, 2026-08-30",
        "- wording: every line has a plain-language headline written for the page and the sheet's own "
        "wording one tap below; where they disagree, the sheet is the source",
        "- verdicts: a verdict is the sheet's opinion on its day, not a node's state; read a node's "
        "state on the node",
        "- dated: the sheet was cut on 2026-08-29 against the grammar of that day; on 2026-08-30 the "
        "ruled types entered the grammar and every node was retyped in place under "
        "[LINK: DEC-NODE-FAMILIES], keeping its UID under [LINK: DEC-UID-OUTLIVES-TYPE], so a row "
        "that says a type is absent, or that a retype re-mints a UID, describes the day before; the "
        "Types tab says what holds now, and rows are re-cut, never edited",
    ])
    new_narrative(START_SOURCE, "Where this comes from", "facts", source, dirpath=PLAN, place="section")

    set_contains_order(ROOT_UID, [
        LEGEND_UID, START_SOLID, START_KINDS, START_LAYERS, START_GAPS, START_SOURCE,
        TYPES_UID, TOPICS_UID, GAPS_UID, EDGES_UID, WORDS_UID, SHEET_UID,
    ])


# --------------------------------------------------------------------------
# 4. the Edges tab
# --------------------------------------------------------------------------

EDGE_RULES = [
    "- Governed_By: DECISION, REQUIREMENT",
    "- Crosses: MECHANISM",
    "- Proven_By: EVIDENCE",
    "- Covered_By: REQUIREMENT, DECISION, MECHANISM",
    "- Cites: any",
    "- Contains: NARRATIVE",
    "- Over: NARRATIVE",
    "- Guarantees: REQUIREMENT",
    "- Assumes: DECISION, MECHANISM",
    "- Superseded_By: DECISION",
    "- Produces: EVIDENCE",
    "- Backlogged_In: MECHANISM",
]


def step_edges() -> None:
    new_narrative(
        EDGES_RULES, "Which relations are allowed", "rows",
        "Each role and the kinds of node it may point at, read from the grammar's comments and the "
        "sheet's allowed-edges lines. The parser checks none of this; a live pair off the rule is "
        "flagged on the figure above.\n\n" + "\n".join(EDGE_RULES),
        dirpath=PLAN, place="section",
    )
    new_narrative(
        EDGES_FINGERPRINTS, "Where fingerprints may point", "fingerprints",
        "Fingerprints point strictly down the ladder, so a collectable node never has an inbound "
        "fingerprint to strand; a live pair off the ladder is flagged.\n\n"
        "- DECISION > MECHANISM > WORK > NARRATIVE",
        dirpath=PLAN, place="section",
    )
    new_narrative(
        EDGES_ON_THE_SHEET, "On the sheet", "rows",
        "The sheet's own lines on which relations are allowed, mirrored from the topic; each line "
        "links home to its place among its neighbours.",
        dirpath=PLAN, place="section", over=ALLOWED_EDGES_UID,
    )
    set_contains_order(EDGES_UID, [EDGES_RULES, EDGES_FINGERPRINTS, EDGES_ON_THE_SHEET])


# --------------------------------------------------------------------------
# 5. the 145 topic rows
# --------------------------------------------------------------------------

TRAILER_RE = re.compile(r"^(?:See |Speaks about |Feeds )")


def rewrite_row(old: str, line: dict, auth: dict, where: str) -> str:
    m = BRACKET_RE.match(old)
    assert m, f"{where}: row without bracket: {old[:60]}"
    text, word, by = m.group("text"), m.group("word").strip(), (m.group("by") or "").strip()
    assert word == line["tag"], f"{where}: bracket {word!r} != sheet tag {line['tag']!r}"
    assert by == line["by"], f"{where}: by {by!r} != sheet by {line['by']!r}"
    links = LINK_RE.findall(text)
    unwoven = LINK_RE.sub(lambda mm: mm.group(1), text)
    h = auth["h"]
    assert unwoven.startswith(h), f"{where}: headline differs:\n  row: {unwoven[:120]}\n  H:   {h[:120]}"
    rest = unwoven[len(h):].strip()
    for sentence in re.split(r"(?<=\.)\s+(?=[A-Z])", rest) if rest else []:
        assert TRAILER_RE.match(sentence), f"{where}: unexpected trailer {sentence[:80]!r}"
    expected: list[str] = []
    for u in list(line["uids"]) + [TYPE_CARD[t] for t in line["types"]] + [GAP_CARD[g] for g in line["gaps"]]:
        if u not in expected:
            expected.append(u)
    assert set(links) == set(expected), f"{where}: links {sorted(set(links) ^ set(expected))} differ"
    assert "[" not in line["orig"] and "]" not in line["orig"], where
    bracket = f"[{word}]" if not by else f"[{word}: {by}]"
    out = [f"- {h}"]
    if expected:
        out.append(" ".join(f"[LINK: {u}]" for u in expected))
    out.append(f"> {line['orig']} {bracket}")
    return "\n".join(out)


def step_rows() -> None:
    total = 0
    for s in SECTIONS:
        uid = SECTION_UID[s["name"]]
        stmt = node_field(uid, "STATEMENT")
        lines = stmt.split("\n")
        row_idx = [i for i, l in enumerate(lines) if l.startswith("- ")]
        auth = A.H[s["name"]]
        assert len(row_idx) == len(s["lines"]) == len(auth), (uid, len(row_idx), len(s["lines"]), len(auth))
        if any(l.startswith("> ") for l in lines):
            note(f"{uid}: rows already carry source lines; skipped")
            total += len(row_idx)
            continue
        head = lines[: row_idx[0]]
        assert all(not l.startswith("> ") for l in lines[row_idx[0]:]), uid
        # every row is one line today: nothing between two row starts
        assert row_idx == list(range(row_idx[0], row_idx[0] + len(row_idx))), uid
        new_rows = [
            rewrite_row(lines[i][2:], s["lines"][k], auth[k], f"{uid} row {k + 1}")
            for k, i in enumerate(row_idx)
        ]
        tail = lines[row_idx[-1] + 1 :]
        assert not any(t.strip() for t in tail), (uid, tail)
        new_stmt = "\n".join(head) + "\n" + "\n".join(new_rows)
        set_fields(uid, statement=new_stmt)
        total += len(new_rows)
        bump("topic rows rewritten", len(new_rows))
    note(f"topic rows: {total}")


# --------------------------------------------------------------------------
# 6. the canon root
# --------------------------------------------------------------------------


def step_canon() -> None:
    set_fields(CANON_SYSTEMS, place="card", tags="systems")
    new_narrative(
        CANON_START_COUNTS, "What the canon holds", "index",
        "Every node of the canon, counted by type and by where it lives, over the systems switched on.",
        dirpath=SPEC, place="section", tags="nodes",
    )
    canon_grid = [
        GRID_INTRO.replace("Tap a cell.", "Each cell links the type's own screen. Tap a cell."),
        "",
        *GRID_ROWS,
    ]
    new_narrative(CANON_TYPES_GRID, "The grid", "grid", "\n".join(canon_grid), dirpath=SPEC, place="card")
    new_narrative(
        CANON_TYPES_LADDERS, "The state fields every type shares", "ladder",
        LADDER_INTRO + "\n\n" + "\n".join(LADDER_ROWS), dirpath=SPEC, place="card",
    )
    new_narrative(
        CANON_TYPES, "Types", "prose",
        "The kinds of node the grammar spells, in four families of which only the first is a grid "
        "([LINK: DEC-NODE-FAMILIES]): definition, the claims the canon asserts; coverage, the use "
        "case; representation, the narrative; and work. The grid card places each kind, and the "
        "ladders card draws the state fields with their live counts. A UID's prefix names the kind "
        "a node was born with, not the kind it is ([LINK: DEC-UID-OUTLIVES-TYPE]); read the tag.",
        dirpath=SPEC, place="tab", contains=[CANON_TYPES_GRID, CANON_TYPES_LADDERS],
    )
    new_narrative(
        CANON_EDGES, "Edges", "edges",
        "Which kinds of node point at which over the whole canon, with the live count on each arrow, "
        "drawn over the systems switched on. An arrow runs from the node that depends to the node "
        "depended on, which is the direction a Parent relation is written; a Child role -- Contains, "
        "Produces -- runs from the owner down and is never a dependency. The parser checks only that "
        "a role is registered on the source type and that the target exists; direction, target type "
        "and cycles are this repository's own rules.",
        dirpath=SPEC, place="tab",
    )
    new_narrative(
        CANON_WORDS, "Words", "glossary",
        "The ruled words: every term narrative in the canon, each citing the decision that ruled it. "
        "Use them, and correct drift on sight.",
        dirpath=SPEC, place="tab", tags="terms",
    )
    new_narrative(
        CANON_WHITEBOARDS, "Whiteboards", "index",
        "Every view written over the canon, one card each: a view is a tree of narratives whose root "
        "nothing contains, and it appears here by being written.",
        dirpath=SPEC, place="tab", tags="roots",
    )
    new_narrative(
        CANON, "The canon", "callout",
        "This page is the canon: every root narrative and every node of the committed, human-reviewed "
        "contents, rendered from one export. The systems table beneath is the switches. Each row names "
        "a set of node types and relation roles; a node shows when any system that holds it is on, and "
        "an edge when both its ends show and its role belongs to a system that is on "
        "([LINK: DEC-SYSTEM-IS-A-TYPE-SET]). Switching changes what is shown and never what was "
        "rendered, and the selection rides in the page's address so a link carries it.",
        dirpath=SPEC,
        contains=[CANON_SYSTEMS, CANON_START_COUNTS, CANON_TYPES, CANON_EDGES, CANON_WORDS, CANON_WHITEBOARDS],
    )
    set_contains_order(CANON, [CANON_SYSTEMS, CANON_START_COUNTS, CANON_TYPES, CANON_EDGES, CANON_WORDS, CANON_WHITEBOARDS])


# --------------------------------------------------------------------------
# 7. export, checks, verification
# --------------------------------------------------------------------------


def export() -> Path:
    if EXPORT.exists():
        shutil.rmtree(EXPORT)
    r = run([str(STRICTDOC), "export", str(ROOT), "--formats=json", "--output-dir", str(EXPORT)], check=False)
    if r.returncode != 0:
        print(r.stdout[-3000:])
        print(r.stderr[-3000:])
        raise SystemExit("export failed")
    hits = list(EXPORT.rglob("index.json"))
    assert len(hits) == 1, hits
    note(f"export: exit 0, {hits[0]}")
    return hits[0]


def checks(index: Path) -> None:
    cmds = [
        ("sdoc check", [str(SDOC), "check"]),
        ("fp-check", [sys.executable, str(SCRIPTS / "fp-check.py"), str(index)]),
        ("cycle-check", [sys.executable, str(SCRIPTS / "cycle-check.py"), str(index)]),
        ("file-check", [sys.executable, str(SCRIPTS / "file-check.py"), str(index), str(ROOT)]),
    ]
    vc = VIEW / "view-check.py"
    if vc.exists():
        for root in (ROOT_UID, CANON, "NAR-WHITEBOARD-VIEW", "NAR-MECHANISM-MOOD-REVIEW"):
            cmds.append((f"view-check {root}", [sys.executable, str(vc), str(index), str(ROOT), "--root", root]))
    for name, cmd in cmds:
        r = run(cmd, check=False)
        out = (r.stdout + r.stderr).strip()
        lines = out.split("\n")
        summary = "\n".join(lines[:40]) + (f"\n... ({len(lines) - 40} more lines)" if len(lines) > 40 else "")
        note(f"[{name}] exit {r.returncode}\n{summary}")


def verify(index: Path) -> list[str]:
    by_uid = build_uid_index(load_index(index))
    problems: list[str] = []

    # rows: count unchanged, every row has a source line, a reference line where it had links
    no_links = 0
    for s in SECTIONS:
        uid = SECTION_UID[s["name"]]
        stmt = by_uid[uid]["STATEMENT"]
        lines = stmt.split("\n")
        starts = [i for i, l in enumerate(lines) if l.startswith("- ")]
        if len(starts) != len(s["lines"]):
            problems.append(f"{uid}: {len(starts)} rows, sheet has {len(s['lines'])}")
        for k, i in enumerate(starts):
            end = starts[k + 1] if k + 1 < len(starts) else len(lines)
            body = lines[i:end]
            refs = [l for l in body[1:] if l.startswith("[LINK: ") and LINK_RE.sub("", l).strip() == ""]
            src = [l for l in body[1:] if l.startswith("> ")]
            if len(src) != 1:
                problems.append(f"{uid} row {k + 1}: {len(src)} source lines")
            elif not BRACKET_RE.match(src[0]) or BRACKET_RE.match(src[0]).group("word") == "LINK":
                problems.append(f"{uid} row {k + 1}: bracket not on the source line")
            expected_links = bool(s["lines"][k]["uids"] or s["lines"][k]["types"] or s["lines"][k]["gaps"])
            if expected_links and len(refs) != 1:
                problems.append(f"{uid} row {k + 1}: {len(refs)} reference lines")
            if not expected_links:
                no_links += 1
                if refs:
                    problems.append(f"{uid} row {k + 1}: reference line on a row the sheet gave no links")
            if LINK_RE.search(body[0]):
                problems.append(f"{uid} row {k + 1}: link left in the headline")
    note(f"rows the sheet gave no links (headline + source only): {no_links}")

    # no relation from docs/spec into docs/plans
    files = uid_files()
    for uid, node in by_uid.items():
        f = files.get(uid)
        if f is None or not rel(f).startswith("docs/spec/"):
            continue
        for r in node.get("RELATIONS") or []:
            if r.get("TYPE") == "Parent" and rel(files[r["VALUE"]]).startswith("docs/plans/"):
                problems.append(f"{uid} ({rel(f)}) {r.get('ROLE')} {r['VALUE']} in a plan")
        for parent, _h in parse_parent_fp(node.get("PARENT_FP")):
            if rel(files[parent]).startswith("docs/plans/"):
                problems.append(f"{uid} PARENT_FP names {parent} in a plan")

    # every narrative contained at most once
    contained: dict[str, str] = {}
    for uid, node in by_uid.items():
        for r in node.get("RELATIONS") or []:
            if r.get("TYPE") == "Child" and r.get("ROLE") == "Contains":
                if r["VALUE"] in contained:
                    problems.append(f"{r['VALUE']} contained by both {contained[r['VALUE']]} and {uid}")
                contained[r["VALUE"]] = uid
    roots = sorted(u for u, n in by_uid.items() if n.get("_NODE_TYPE") == "NARRATIVE" and u not in contained)
    note(f"roots (narratives nothing Contains): {', '.join(roots)}")

    # PARENT_FP entries match Cites on every narrative touched here
    for uid, node in by_uid.items():
        if node.get("_NODE_TYPE") != "NARRATIVE":
            continue
        cites = {r["VALUE"] for r in node.get("RELATIONS") or [] if r.get("ROLE") == "Cites"}
        fp = {u for u, _ in parse_parent_fp(node.get("PARENT_FP"))}
        if fp - cites:
            problems.append(f"{uid}: PARENT_FP names {sorted(fp - cites)} it does not cite")

    # the places
    want = {**{u: "tab" for u in TABS}, SHEET_UID: "tab", LEGEND_UID: "card"}
    want.update({u: "screen" for u in list(TYPE_CARD.values()) + list(SECTION_UID.values()) + list(GAP_CARD.values())})
    for uid, place in want.items():
        if by_uid[uid].get("PLACE") != place:
            problems.append(f"{uid}: PLACE {by_uid[uid].get('PLACE')!r}, wanted {place!r}")
    for uid in TYPE_CARD.values():
        if not rel(files[uid]).startswith("docs/spec/"):
            problems.append(f"{uid} still in {rel(files[uid])}")
    return problems


def main() -> int:
    TMP.mkdir(parents=True, exist_ok=True)
    step_places()
    step_types()
    step_start()
    step_edges()
    step_rows()
    step_canon()
    index = export()
    checks(index)
    problems = verify(index)
    note("counts: " + ", ".join(f"{k}={v}" for k, v in sorted(COUNTS.items())))
    if problems:
        note(f"VERIFY: {len(problems)} problem(s)")
        for p in problems:
            note("  " + p)
    else:
        note("VERIFY: clean")
    (WORK / "migrate.log").write_text("\n".join(LOG) + "\n")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
