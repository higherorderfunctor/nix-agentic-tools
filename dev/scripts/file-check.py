#!/usr/bin/env python3
# cspell:ignore uids unbuilt
"""file-check -- MECH-FILE-RELATION-EXISTENCE. Check every File relation
against the repository tree.

Usage: file-check.py <export.json> <repo-root>

A File relation to a path that does not exist EXPORTS CLEAN: strictdoc's
own file-traceability validation is off here, so a node can point at a file
that was deleted or moved and nothing notices. That is the direction the
ghost problem actually runs, and it is why a write-time check cannot
replace this one -- dev/scripts/sdoc_cli.py checks the VALUEs it is about to
write, which says nothing about a file removed afterwards.

A VALUE is well-formed in exactly one shape: a normalized POSIX path
relative to the repository root, not absolute, with no leading `./` and no
`..` segment, naming an existing REGULAR FILE. A directory is a finding.
That rule is upstream's rather than ours -- strictdoc accepts precisely this
shape and rejects `./x`, `../x`, an absolute path and a directory with the
same message -- so holding to it keeps the corpus able to turn that feature
on later.

Two exclusions, both deliberate and both cheap to reverse. Targets outside
the repository are not supported; no File relation names one today. Forward
references are not supported either -- a node may not name a path its own
unbuilt work will create. Relaxing that later by gating existence on DEPTH
is a one-line change, where tightening it later would not be.

The second argument is the repository root, which neither cycle-check.py nor
fp-check.py takes: the JSON export carries no path for anything, so there is
nothing in it to resolve a relative path against.

Generate the export first with a CLEAN output directory -- incremental
export produces false greens (see the sdoc skill's gotcha list):

    rm -rf output && strictdoc export . --formats=json --output-dir output
    dev/scripts/file-check.py output/json/index.json .
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sdoc_fp import iter_nodes, load_index


def malformed(value: str) -> str | None:
    """The reason `value` is not a well-formed File VALUE, or None."""
    if value != value.strip():
        return "has leading or trailing whitespace"
    if not value:
        return "is empty"
    if value.startswith("/"):
        return "is absolute"
    if "\\" in value:
        return "is not a POSIX path"
    parts = value.split("/")
    if "." in parts:
        return "has a './' segment"
    if ".." in parts:
        return "has a '..' segment"
    if "" in parts:
        return "has an empty path segment"
    return None


def check(index: dict, repo_root: Path) -> list:
    findings = []
    for document_title, node in iter_nodes(index):
        uid = node.get("UID", "(no UID)")
        for relation in node.get("RELATIONS", []) or []:
            if relation.get("TYPE") != "File":
                continue
            value = relation.get("VALUE", "")
            reason = malformed(value)
            if reason is not None:
                findings.append((document_title, uid, value, reason))
                continue
            target = repo_root / value
            if target.is_dir():
                findings.append((document_title, uid, value, "is a directory"))
            elif not target.is_file():
                findings.append((document_title, uid, value, "does not exist"))
    return findings


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("export_json", type=Path)
    parser.add_argument("repo_root", type=Path)
    args = parser.parse_args()

    findings = check(load_index(args.export_json), args.repo_root.resolve())
    for document_title, uid, value, reason in findings:
        print(f"{uid} ({document_title}): File relation {value!r} {reason}", file=sys.stderr)

    total = sum(
        1
        for _, node in iter_nodes(load_index(args.export_json))
        for relation in (node.get("RELATIONS", []) or [])
        if relation.get("TYPE") == "File"
    )
    print(f"{total} File relation(s) checked: {len(findings)} finding(s)")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
