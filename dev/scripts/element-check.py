#!/usr/bin/env python3
# cspell:ignore attrpath sdoc uids
"""element-check -- every element-grained File relation, resolved against the
file it points into.

Usage: element-check.py <repo-root>

    strictdoc-grammar-extract dev/scripts/element-check.py .

THE FAILURE IT CLOSES IS SILENT IN BOTH DIRECTIONS. A forward `ID:` that
resolves to nothing is not an error to strictdoc: it exits 0, creates no
marker, and the relation is absent from the document page and the source page
alike. A corpus full of ghost ids and a corpus that is entirely sound produce
the same exit code and the same rendered site. dev/scripts/file-check.py
cannot see it either -- that gate checks the PATH and never opens the file.

WHY A SEPARATE GATE FROM THE WRITE-TIME CHECK. dev/scripts/sdoc_model.py
refuses an id that names no item at the moment a relation is written, which
says nothing about a file REFACTORED afterwards. Renaming a binding, or moving
an option under a different attrpath, turns a sound relation into a ghost with
no edit to any `.sdoc` at all -- and that is the direction this problem
actually runs, the same asymmetry MECH-FILE-RELATION-EXISTENCE records for
whole-file relations.

WHY IT READS THE MODEL AND NOT AN EXPORT, unlike file-check.py and
cycle-check.py. `strictdoc export --formats=json` DROPS ELEMENT and ID:
JSONGenerator._write_requirement_relations reads only TYPE, FORMAT, VALUE and
LINE_RANGE off a FileReference, and sdoc_model.carry_file_element_into_json()
is the patch that restores them -- applied by the daemon's export, not by the
strictdoc CLI. A gate reading a bare `strictdoc export` would therefore find
ZERO element-grained relations in a corpus that has three, print "0 checked, 0
findings", and be green forever. Measured 2026-09-02. Loading the graph
directly is also cheaper (about 1.7 s against 2.5 s for the export) and skips
the clean-output-directory hazard that makes an incremental export a false
green.

COST. Only the REFERENCED files are parsed -- one tree-sitter parse each --
not the 1300-file corpus walk. The extractor table is
dev/scripts/sdoc_extractors/registry.py, the same one the write path and
strictdoc_config.py read; a second table here could pass a relation that
resolves to nothing where it counts.

AN EMPTY RELATION SET IS NOT A FAILURE, and it is REPORTED rather than
silently green: a corpus that has not yet grown an element-grained relation is
a legitimate state, but "0 checked, 0 findings" and "40 checked, 0 findings"
must not print the same line, or a gate that stopped seeing relations at all
would read exactly like a clean one.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from sdoc_extractors import registry  # noqa: E402
from sdoc_extractors.tree_sitter_extractor import ExtractorError  # noqa: E402
from sdoc_model import (  # noqa: E402
    FileReference,
    SdocError,
    file_entry_of,
    file_path_of,
    open_graph,
)


def relations(graph):
    """(document title, uid, path, element, id) per element-grained relation."""
    for node in graph.iter_nodes():
        for relation in node.relations:
            if not isinstance(relation, FileReference):
                continue
            entry = file_entry_of(relation)
            if not entry["element"] and not entry["id"]:
                continue
            document = node.get_document()
            yield (
                getattr(document, "title", None) or "?",
                node.reserved_uid or "(no UID)",
                file_path_of(relation),
                entry["element"],
                entry["id"],
            )


def reason_for(repo_root: Path, value: str, element, identifier) -> str | None:
    """Why this one relation does not resolve, or None when it does."""
    if not identifier:
        # strictdoc's own writer drops a lone ELEMENT on the next format, so
        # this degrades to a whole-file relation with no diagnostic.
        return f"carries ELEMENT {element!r} with no ID, so it names no item"
    target = repo_root / value
    if not target.is_file():
        # file-check.py owns this finding; resolving it here too would double
        # every report when a path is deleted. Named, not re-derived.
        return "names a path that does not exist (see file-check)"
    try:
        items = registry.items_of(target, path_root=repo_root)
    except registry.UnsupportedPath:
        return (
            f"names an ID, but no source extractor covers that path "
            f"(globs: {registry.describe_globs()})"
        )
    except ExtractorError as error:
        return f"could not be parsed: {error}"
    item = next((one for one in items if one.display_name == identifier), None)
    if item is None:
        return registry.explain_missing_id(
            target, identifier, items, path_root=repo_root
        )
    if not element:
        return None
    spec = registry.extractor_for(target, repo_root)
    expected = spec.kind_elements.get(item.kind) if spec else None
    if expected is None or element == expected:
        return None
    # Derived from the same table the reader uses, so this is not a taste
    # disagreement: the item WILL render under `expected`, and a relation
    # asking for anything else names a marker type the resolver does not
    # produce for it.
    return (
        f"declares ELEMENT {element!r} but {identifier!r} is a {item.kind}, "
        f"which reads as ELEMENT {expected!r}"
    )


def check(graph, repo_root: Path) -> tuple[list, int]:
    """(findings, relations checked). A finding is (document, uid, path, id, reason)."""
    findings: list = []
    checked = 0
    for document_title, uid, value, element, identifier in relations(graph):
        checked += 1
        reason = reason_for(repo_root, value, element, identifier)
        if reason is not None:
            findings.append((document_title, uid, value, identifier, reason))
    return findings, checked


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("repo_root", type=Path)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=None,
        help="where the parse cache is keyed against; a writable scratch "
        "directory when the repository root is read-only",
    )
    args = parser.parse_args()

    repo_root = args.repo_root.resolve()
    try:
        graph = open_graph(repo_root, output_dir=args.output_dir)
    except SdocError as error:
        print(f"element-check: {error}", file=sys.stderr)
        return 2

    findings, checked = check(graph, repo_root)
    for document_title, uid, value, identifier, reason in findings:
        print(
            f"{uid} ({document_title}): File relation {value!r} "
            f"ID {identifier!r}: {reason}",
            file=sys.stderr,
        )
    print(
        f"{checked} element-grained File relation(s) checked: "
        f"{len(findings)} finding(s)"
    )
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
