#!/usr/bin/env python3
# cspell:ignore uids sgra
"""wireline -- MECH-VIEW-WIRELINE. One versioned JSON payload for the whole
canon, computed from the strictdoc export for the renderer and nothing else.

    strictdoc export . --formats=json --output-dir /tmp/sdoc-out
    python3 docs/sdoc/view/wireline.py /tmp/sdoc-out/json/index.json . --out view.json               # every root
    python3 docs/sdoc/view/wireline.py /tmp/sdoc-out/json/index.json . --root NAR-X --out view.json  # one root

Schema "whiteboard-view/2". Field values pass through verbatim; everything
computed sits under a key that says so:

  generated   canon_commit (git HEAD of the worktree, null outside a
              repository), export_sha256 (of the index.json bytes), at,
              roots (the UIDs of the roots in this payload)
  systems     the systems table (queries.systems), read from the narrative
              tagged systems
  tabs        the tab strip's vocabulary (queries.tabs), read from the
              narrative tagged tabs; a narrative names its tab in TAGS
  colours     what each colour means page-wide (queries.colours), read from
              the narrative tagged colours; a system's legend words map onto it
  roots       every NARRATIVE nothing Contains (or the one asked for),
              spec first, then by directory, then UID; each root's tree
              fully expanded in Contains order, every STATEMENT parsed per
              its WIDGET (view-check.parse_statement)
  nodes       a card per node in the export: type, path, dir_class, the
              systems that hold it (by path), its state, every other field verbatim
              in grammar order, relations out and in, files, fingerprints
  edges       every Parent or Child relation whose target is a node of the
              export, whole canon
  backlinks   per node, which narratives point at it and how: a Cites, a
              link span in prose or in row n (with the row's bracket word),
              a link on row n's reference line, a row's "by" that names a
              UID (as a link), a glossary term whose text is the TITLE of a
              term narrative the glossary Contains, an Over relation, or a
              grid row that places it in a cell or the outside strip; one
              entry per (narrative, row), whichever via was seen first
  grammar     every element's prefix, fields (kind, options, required) and
              relation roles, from the grammar file: the export types every
              field as String
  ladders     every SingleChoice field's option list, from the grammar
  checks      view-check's findings, per root and canon-wide, the same list
              its own output prints
  queries     the tables the query words compute that have no other key:
              roots, terms, nodes (queries.py); systems and grammar are the
              keys above

Per Cites the payload says whether the citation is undeclared (no PARENT_FP
entry), unsigned (the placeholder), signed (the recorded hash equals the
contract hash recomputed with dev/scripts/sdoc_fp.py, imported not copied;
PLACE is excluded there, so moving a card never dirties its citers) or
drifted, and whether the target is superseded. A narrative names its Over
target, its query word (TAGS among the closed list) and grammar_of (a TAGS
word that is a grammar element) so the renderer can pick a subject without
knowing any UID, tag or type name. Counts -- strips, tallies, indexes,
edge pairs, fingerprint pairs, ladder counts, node facets -- are the
renderer's to compute over the selection; the payload is the same file
whatever the system switches say.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import importlib.util
import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve()
sys.path.insert(0, str(HERE.parents[3] / "dev" / "scripts"))
from sdoc_fp import PLACEHOLDER, contract_hash, parse_parent_fp  # noqa: E402


def _import(name: str):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), HERE.with_name(f"{name}.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


vc = _import("view-check")
queries = _import("queries")

STATE_FIELDS = queries.STATE_FIELDS
UID_TOKEN_RE = re.compile(r"[A-Z][A-Z0-9]*(?:-[A-Z0-9]+)+")
CARD_HEAD = {"UID", "TITLE", *STATE_FIELDS}


def canon_commit(worktree: Path):
    try:
        out = subprocess.run(
            ["git", "-C", str(worktree), "rev-parse", "HEAD"],
            capture_output=True, text=True, check=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    return out.stdout.strip() or None


class Wireline:
    def __init__(self, canon):
        self.canon = canon
        self.by_uid = canon.by_uid
        self.grammar = canon.grammar
        self.colours = queries.colours(canon)
        if not self.colours:
            raise SystemExit("wireline: the canon has no colours table, or its header is not " + " | ".join(vc.COLOURS_HEADER))
        self.tabs = queries.tabs(canon)
        if not self.tabs:
            raise SystemExit("wireline: the canon has no tabs table, or its header is not " + " | ".join(vc.TABS_HEADER))
        self.systems = queries.systems(canon)
        if not self.systems:
            # An empty table reads to the renderer as "no switches at all",
            # because every gate there short-circuits on SYSTEMS.length. A
            # header typo would therefore ship a page that quietly shows
            # everything. Refuse instead.
            raise SystemExit("wireline: the canon has no systems table, or its header is not " + " | ".join(vc.SYSTEMS_HEADER))
        self.inbound: dict = {}
        self.edges: list = []
        for uid, node in self.by_uid.items():
            for r in vc.relations(node):
                if r.get("TYPE") in ("Parent", "Child") and r.get("VALUE") in self.by_uid:
                    self.inbound.setdefault(r["VALUE"], []).append({"role": r.get("ROLE"), "uid": uid})
                    self.edges.append({"from": uid, "role": r.get("ROLE"), "to": r["VALUE"], "type": r["TYPE"]})
        self.backlinks: dict = {}
        self.cited: set = set()
        # Every narrative of the export has a parse: the ones in a walked
        # tree from its View, the rest (other roots' trees under --root)
        # parsed here so backlinks cover the whole canon either way.
        self.parsed: dict = {}
        self.children: dict = {}
        for root in canon.all_roots:
            view = canon.views.get(root) or vc.View(canon, root)
            self.parsed.update(view.parsed)
            self.children.update(view.children)
        self._resolve()

    # -- backlinks over every narrative ----------------------------------

    def _back(self, target: str, source: str, row, via: str, word) -> None:
        """One backlink per (target, source, row): a row whose headline
        links a node, whose reference line names it and whose "by" names
        it again is one row, recorded under the via seen first (the
        reference line is resolved before the headline, so it wins)."""
        if target not in self.by_uid:
            return
        entries = self.backlinks.setdefault(target, [])
        if row is not None and any(e["from"] == source and e["row"] == row for e in entries):
            return
        entries.append({"from": source, "row": row, "via": via, "word": word})

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
        inferred, indistinguishable on the page from one that was written."""
        for child in self.children.get(glossary_uid, []):
            if (self.by_uid[child].get("TITLE") or "").strip() == term:
                return child
        return None

    def _resolve(self) -> None:
        for uid, parsed in self.parsed.items():
            node = self.by_uid[uid]
            for target in vc.cites_targets(node):
                self.cited.add(target)
                self._back(target, uid, None, "cites", None)
            for target in vc.over_targets(node):
                self._back(target, uid, None, "over", None)
            for para in parsed["prose"]:
                for link in vc.link_uids(para):
                    self._back(link, uid, None, "link", None)
            for row in parsed["rows"]:
                for link in row["refs"]:
                    self._back(link, uid, row["n"], "reference", row["word"])
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
            for fact in parsed["facts"]:
                for link in vc.link_uids(fact["spans"]):
                    self._back(link, uid, fact["n"], "link", None)
            for rung in parsed["stack"]:
                for link in vc.link_uids(rung["spans"]):
                    self._back(link, uid, rung["n"], "link", rung["word"])
            if parsed["table"]:
                for n, cells in enumerate(parsed["table"]["rows"], 1):
                    for cell in cells:
                        for link in vc.LINK_RE.findall(cell):
                            self._back(link, uid, n, "link", None)
            grid = parsed["grid"]
            if grid:
                for cell in grid["cells"]:
                    self._back(cell["uid"], uid, cell["n"], "grid", None)
                for target, n in zip(grid["outside"], grid["outside_n"]):
                    self._back(target, uid, n, "grid", None)

    # -- the trees --------------------------------------------------------

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

    def narrative(self, uid: str) -> dict:
        node = self.by_uid[uid]
        parsed = self.parsed[uid]
        tags = vc.tags_of(node)
        grid = parsed["grid"]
        if grid:
            grid = {"axes": grid["axes"], "cells": grid["cells"], "outside": grid["outside"]}
        over = vc.over_targets(node)
        return {
            "uid": uid,
            "title": node.get("TITLE", uid),
            "type": node.get("_NODE_TYPE"),
            "depth": node.get("DEPTH"),
            "authored": node.get("AUTHORED_BY"),
            "widget": vc.widget_of(node),
            "place": vc.place_of(node),
            "tags": tags,
            "tab": queries.tab_of(tags, self.tabs),
            "path": self.canon.paths.get(uid),
            "dir_class": self.canon.dir_class_of(uid),
            "prose": parsed["prose"],
            "rows": parsed["rows"],
            "terms": parsed["terms"],
            "legend": parsed["legend"],
            "table": parsed["table"],
            "facts": parsed["facts"],
            "stack": parsed["stack"],
            "grid": grid,
            "ladder": parsed["ladder"],
            "cites": self.cites(node),
            "over": over[0] if over else None,
            "query": queries.query_of(tags),
            "grammar_of": next((t for t in tags if t in self.grammar), None),
            "children": [self.narrative(child) for child in self.children.get(uid, [])],
        }

    # -- the cards and the rest ------------------------------------------

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
            "path": self.canon.paths.get(uid),
            "dir_class": self.canon.dir_class_of(uid),
            "systems": queries.systems_of(self.canon.paths.get(uid), self.systems),
            "state": {k: node[k] for k in STATE_FIELDS if k in node},
            "fields": {n: node[n] for n in names if n not in CARD_HEAD},
            "out": out_rel,
            "in": list(self.inbound.get(uid, [])),
            "files": files,
            "fp": [{"uid": p, "hash": h} for p, h in parse_parent_fp(node.get("PARENT_FP"))],
        }

    def payload(self, worktree: Path, export_path: Path) -> dict:
        canon = self.canon
        return {
            "schema": vc.SCHEMA,
            "generated": {
                "canon_commit": canon_commit(worktree),
                "export_sha256": hashlib.sha256(export_path.read_bytes()).hexdigest(),
                "at": dt.date.today().isoformat(),
                "roots": list(canon.roots),
            },
            "systems": self.systems,
            "tabs": self.tabs,
            "colours": self.colours,
            "roots": [self.narrative(root) for root in canon.roots],
            "nodes": {uid: self.card(uid) for uid in self.by_uid},
            "edges": self.edges,
            "backlinks": {uid: self.backlinks[uid] for uid in self.by_uid if uid in self.backlinks},
            "grammar": queries.grammar(self.grammar),
            "ladders": vc.ladders(self.grammar),
            "checks": canon.all_findings(),
            "queries": {
                "roots": queries.roots(canon),
                "terms": queries.terms(canon),
                "nodes": queries.nodes(canon, self.systems, self.cited),
            },
        }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("export_json", type=Path)
    parser.add_argument("worktree", type=Path)
    parser.add_argument("--root", help="UID of one root narrative (default: every root)")
    parser.add_argument("--all-roots", action="store_true", help="every root (the default)")
    parser.add_argument("--grammar", type=Path, help="grammar file (default: <worktree>/docs/sdoc/grammar.sgra)")
    parser.add_argument("--out", type=Path, help="write the payload here instead of stdout")
    args = parser.parse_args()

    worktree = args.worktree.resolve()
    if not worktree.is_dir():
        parser.error(f"worktree {worktree} is not a directory")
    if args.root and args.all_roots:
        parser.error("--root and --all-roots exclude each other")
    grammar_path = args.grammar or worktree / "docs" / "sdoc" / "grammar.sgra"
    if not grammar_path.is_file():
        parser.error(f"grammar {grammar_path} does not exist")

    canon = vc.build_canon(vc.load_index(args.export_json), worktree, vc.parse_sgra(grammar_path), [args.root] if args.root else None)
    wire = Wireline(canon)
    text = json.dumps(wire.payload(worktree, args.export_json), indent=2, ensure_ascii=False) + "\n"
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
