#!/usr/bin/env python3
# cspell:ignore uids sgra
"""wireline -- MECH-VIEW-WIRELINE. One versioned JSON payload per root,
computed from the strictdoc export for the renderer and nothing else.

    strictdoc export . --formats=json --output-dir /tmp/sdoc-out
    python3 docs/sdoc/view/wireline.py /tmp/sdoc-out/json/index.json . --root NAR-WHITEBOARD-VIEW --out view.json

Schema "whiteboard-view/1". Field values pass through verbatim; everything
computed sits under a key that says so:

  generated   root, canon_commit (git HEAD of the worktree, null outside a
              repository), export_sha256 (of the index.json bytes), at
  legend      the root's legend child's rows, in order; [] when none
  tree        the narrative tree in Contains order, each STATEMENT parsed
              per its WIDGET (see view-check.parse_statement)
  nodes       a card per node the tree Cites or links, plus every narrative
              in the tree: state, every other field verbatim in grammar
              order, relations out and in, files, fingerprint entries
  backlinks   per node, which narratives point at it and how: a Cites, a
              link span (in prose or in row n, with the row's bracket word),
              a row's "by" that names a UID (whole, or as its first UID-shaped
              token the export knows), or a glossary term whose text is
              the TITLE of a term narrative the glossary Contains
  pairs       (source type, role, target type, count) over the live
              relations among the nodes above -- the edges widget's data
  ladders     every SingleChoice field's option list, from the grammar
  grammar     every element's prefix, fields (kind, options, required) and
              relation roles, from the grammar file: the export types every
              field as String
  checks      view-check's findings for this root, the same list its own
              output prints

Per Cites the payload says whether the citation is undeclared (no PARENT_FP
entry), unsigned (the placeholder), signed (the recorded hash equals the
contract hash recomputed with dev/scripts/sdoc_fp.py, imported not copied)
or drifted, and whether the target is superseded. A tally widget counts,
per child, the row backlinks that point at it grouped by bracket word. A
narrative whose TAGS name a grammar element gets grammar_of so the renderer
can draw that element's grammar beside it without knowing any type name.

The worktree is walked (os.walk, so dotted directories such as
packages/semble/.sdoc are included) to map each UID to the file that holds
it; the export carries no path.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve()
sys.path.insert(0, str(HERE.parents[3] / "dev" / "scripts"))
from sdoc_fp import PLACEHOLDER, contract_hash, parse_parent_fp  # noqa: E402


def _import_view_check():
    spec = importlib.util.spec_from_file_location("view_check", HERE.with_name("view-check.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


vc = _import_view_check()

STATE_FIELDS = ("DEPTH", "STATUS", "AUTHORED_BY")
UID_TOKEN_RE = re.compile(r"[A-Z][A-Z0-9]*(?:-[A-Z0-9]+)+")
CARD_HEAD = {"UID", "TITLE", *STATE_FIELDS}
SKIP_DIRS = {".git", ".devenv"}


# --------------------------------------------------------------------------
# the worktree
# --------------------------------------------------------------------------


def uid_paths(worktree: Path) -> dict:
    """UID -> repo-relative path of the .sdoc that declares it."""
    paths: dict = {}
    for dirpath, dirnames, filenames in os.walk(worktree):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
        for name in sorted(filenames):
            if not name.endswith(".sdoc"):
                continue
            full = Path(dirpath) / name
            rel = full.relative_to(worktree).as_posix()
            with open(full, encoding="utf-8") as fh:
                for line in fh:
                    if line.startswith("UID: "):
                        paths.setdefault(line[5:].strip(), rel)
    return paths


def canon_commit(worktree: Path):
    try:
        out = subprocess.run(
            ["git", "-C", str(worktree), "rev-parse", "HEAD"],
            capture_output=True, text=True, check=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    return out.stdout.strip() or None


# --------------------------------------------------------------------------
# the payload
# --------------------------------------------------------------------------


class Wireline:
    def __init__(self, view, grammar: dict, paths: dict):
        self.view = view
        self.by_uid = view.by_uid
        self.grammar = grammar
        self.paths = paths
        self.tree_set = set(view.order)
        self.inbound: dict = {}
        for uid, node in self.by_uid.items():
            for r in vc.relations(node):
                if r.get("TYPE") in ("Parent", "Child") and r.get("VALUE") in self.by_uid:
                    self.inbound.setdefault(r["VALUE"], []).append({"role": r.get("ROLE"), "uid": uid})
        self.backlinks: dict = {}
        self.node_uids: list = list(view.order)
        self._resolve()

    # -- pass one: by_uid, term links, backlinks, the node set --------------

    def _want(self, uid: str) -> None:
        if uid in self.by_uid and uid not in self.node_uids:
            self.node_uids.append(uid)

    def _back(self, target: str, source: str, row, via: str, word) -> None:
        if target not in self.by_uid:
            return
        self._want(target)
        self.backlinks.setdefault(target, []).append({"from": source, "row": row, "via": via, "word": word})

    def _by_uid(self, by):
        """The UID a row's "by" names: the whole text when that is a UID, else
        the first UID-shaped token in it that the export knows. A "by" that
        names several is linkified on its first; the rest stay text."""
        if not by:
            return None
        if by in self.by_uid:
            return by
        for token in UID_TOKEN_RE.findall(by):
            if token in self.by_uid:
                return token
        return None

    def _term_target(self, glossary_uid: str, term: str):
        """The narrative a glossary row's term names: a child the glossary
        Contains whose TITLE is the term, and nothing else. The relation is
        the author's (DEC-TERMS-ARE-NARRATIVES: the glossary Contains its
        terms); a corpus-wide match on TITLE would be an edge this script
        inferred, indistinguishable on the page from one that was written.
        A row that should point elsewhere carries a [LINK: UID] instead."""
        for child in self.view.children.get(glossary_uid, []):
            if (self.by_uid[child].get("TITLE") or "").strip() == term:
                return child
        return None

    def _resolve(self) -> None:
        for uid in self.view.order:
            node = self.by_uid[uid]
            parsed = self.view.parsed[uid]
            for target in vc.cites_targets(node):
                self._back(target, uid, None, "cites", None)
            for para in parsed["prose"]:
                for link in vc.link_uids(para):
                    self._back(link, uid, None, "link", None)
            for row in parsed["rows"]:
                for link in vc.link_uids(row["spans"]):
                    self._back(link, uid, row["n"], "link", row["word"])
                by_uid = self._by_uid(row["by"])
                if by_uid is not None:
                    row["by_uid"] = by_uid
                    self._back(by_uid, uid, row["n"], "link", row["word"])
            for term in parsed["terms"]:
                for link in vc.link_uids(term["spans"]):
                    self._back(link, uid, term["n"], "link", None)
                target = self._term_target(uid, term["term"])
                if target is not None:
                    self._back(target, uid, term["n"], "term", None)

    # -- pass two: the tree ----------------------------------------------

    def cites(self, node: dict) -> list:
        recorded = dict(parse_parent_fp(node.get("PARENT_FP")))
        out = []
        for target in vc.cites_targets(node):
            cited = self.by_uid.get(target)
            if target not in recorded:
                fp = "undeclared"
            elif recorded[target] == PLACEHOLDER:
                fp = "unsigned"
            elif cited is not None and recorded[target] == contract_hash(cited):
                fp = "signed"
            else:
                fp = "drifted"
            out.append({"uid": target, "fp": fp, "superseded": bool(cited and vc.is_superseded(cited))})
        return out

    def tally(self, uid: str) -> list:
        out = []
        for child in self.view.children.get(uid, []):
            by_word: dict = {}
            total = 0
            for b in self.backlinks.get(child, []):
                if b["row"] is None:
                    continue
                total += 1
                if b["word"] is not None:
                    by_word[b["word"]] = by_word.get(b["word"], 0) + 1
            out.append({"uid": child, "title": self.by_uid[child].get("TITLE", child), "by_word": by_word, "total": total})
        return out

    def narrative(self, uid: str) -> dict:
        node = self.by_uid[uid]
        parsed = self.view.parsed[uid]
        tags = vc.tags_of(node)
        widget = vc.widget_of(node)
        grammar_of = next((t for t in tags if t in self.grammar), None)
        return {
            "uid": uid,
            "title": node.get("TITLE", uid),
            "depth": node.get("DEPTH"),
            "authored": node.get("AUTHORED_BY"),
            "widget": widget,
            "tags": tags,
            "path": self.paths.get(uid),
            "prose": parsed["prose"],
            "rows": parsed["rows"],
            "terms": parsed["terms"],
            "legend": parsed["legend"],
            "table": parsed["table"],
            "cites": self.cites(node),
            "tally": self.tally(uid) if widget == "tally" else [],
            "grammar_of": grammar_of,
            "children": [self.narrative(child) for child in self.view.children.get(uid, [])],
        }

    # -- the cards, pairs and the rest -----------------------------------

    def card(self, uid: str) -> dict:
        node = self.by_uid[uid]
        node_type = node.get("_NODE_TYPE")
        order = [f["name"] for f in self.grammar.get(node_type, {}).get("fields", [])]
        names = [n for n in order if n in node] + [n for n in node if n not in order and not n.startswith("_") and n != "RELATIONS"]
        out_rel, files = [], []
        for r in vc.relations(node):
            if r.get("TYPE") == "File":
                files.append(r.get("VALUE"))
            elif r.get("TYPE") in ("Parent", "Child"):
                out_rel.append({"role": r.get("ROLE"), "uid": r.get("VALUE"), "type": r["TYPE"]})
        return {
            "uid": uid,
            "type": node_type,
            "title": node.get("TITLE", uid),
            "path": self.paths.get(uid),
            "state": {k: node[k] for k in STATE_FIELDS if k in node},
            "fields": {n: node[n] for n in names if n not in CARD_HEAD},
            "out": out_rel,
            "in": list(self.inbound.get(uid, [])),
            "files": files,
            "fp": [{"uid": p, "hash": h} for p, h in parse_parent_fp(node.get("PARENT_FP"))],
        }

    def pairs(self) -> list:
        members = set(self.node_uids)
        counts: dict = {}
        for uid in self.node_uids:
            src = self.by_uid[uid].get("_NODE_TYPE")
            for r in vc.relations(self.by_uid[uid]):
                if r.get("TYPE") in ("Parent", "Child") and r.get("VALUE") in members:
                    key = (src, r.get("ROLE"), self.by_uid[r["VALUE"]].get("_NODE_TYPE"))
                    counts[key] = counts.get(key, 0) + 1
        return [[s, role, t, n] for (s, role, t), n in sorted(counts.items())]

    def payload(self, worktree: Path, export_path: Path) -> dict:
        return {
            "schema": vc.SCHEMA,
            "generated": {
                "root": self.view.root,
                "canon_commit": canon_commit(worktree),
                "export_sha256": hashlib.sha256(export_path.read_bytes()).hexdigest(),
                "at": dt.date.today().isoformat(),
            },
            "legend": list(self.view.legend),
            "tree": self.narrative(self.view.root),
            "nodes": {uid: self.card(uid) for uid in self.node_uids},
            "backlinks": {uid: self.backlinks[uid] for uid in self.node_uids if uid in self.backlinks},
            "pairs": self.pairs(),
            "ladders": vc.ladders(self.grammar),
            "grammar": self.grammar,
            "checks": list(self.view.findings),
        }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("export_json", type=Path)
    parser.add_argument("worktree", type=Path)
    parser.add_argument("--root", required=True, help="UID of the root narrative")
    parser.add_argument("--grammar", type=Path, help="grammar file (default: <worktree>/docs/sdoc/grammar.sgra)")
    parser.add_argument("--out", type=Path, help="write the payload here instead of stdout")
    args = parser.parse_args()

    worktree = args.worktree.resolve()
    if not worktree.is_dir():
        parser.error(f"worktree {worktree} is not a directory")
    grammar_path = args.grammar or worktree / "docs" / "sdoc" / "grammar.sgra"
    if not grammar_path.is_file():
        parser.error(f"grammar {grammar_path} does not exist")

    index = vc.load_index(args.export_json)
    view = vc.build(index, args.root)
    wire = Wireline(view, vc.parse_sgra(grammar_path), uid_paths(worktree))
    text = json.dumps(wire.payload(worktree, args.export_json), indent=2, ensure_ascii=False) + "\n"
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
