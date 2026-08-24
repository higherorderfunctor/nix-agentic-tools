#!/usr/bin/env python3
# cspell:ignore uids
"""fp-accept -- SLICE-FP-DETECTOR. Sign PARENT_FP entries to current hashes.

Usage: fp-accept.py <export.json> --repo-root PATH UID [UID ...]

For each named node, recomputes the hash of every parent it has a `Parent`
relation to (any role) and writes a PARENT_FP entry for it -- unless
MECH-FP-ACCEPT-READINESS refuses: a MECHANISM/SLICE/INVARIANT/SPIKE parent
below interface-settled, or a DECISION parent whose STATUS is open.

This is the ONLY thing that writes PARENT_FP (DEC-FINGERPRINT-IN-NODE). It
edits the node's SOURCE .sdoc file directly, found by scanning
docs/plans/**/*.sdoc and **/.sdoc/*.sdoc for a `UID: <uid>` line -- the JSON
export carries no source-file pointer.

Run `strictdoc format .` and re-export with a clean output directory
afterward -- this script does neither for you, and a stale export is what
produces the false-green gotcha the sdoc skill warns about.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sdoc_edit import set_parent_fp
from sdoc_fp import build_uid_index, contract_hash, format_parent_fp, is_ready, load_index, parse_parent_fp, relation_parent_uids


def discover_sdoc_files(repo_root: Path) -> list:
    """Source locations per the sdoc skill's Layout table."""
    files = list((repo_root / "docs" / "plans").rglob("*.sdoc"))
    files += list(repo_root.rglob(".sdoc/*.sdoc"))
    return files


def find_source_file(files: list, uid: str):
    needle = f"UID: {uid}"
    for f in files:
        if needle in f.read_text():
            return f
    return None


def accept(index: dict, repo_root: Path, uids: list) -> int:
    by_uid = build_uid_index(index)
    files = discover_sdoc_files(repo_root)
    exit_code = 0

    for uid in uids:
        node = by_uid.get(uid)
        if node is None:
            print(f"error: {uid} not found in export", file=sys.stderr)
            exit_code = 1
            continue

        node_type = node["_NODE_TYPE"]
        if node_type == "DECISION":
            print(f"error: {uid} is a DECISION -- decisions carry no PARENT_FP", file=sys.stderr)
            exit_code = 1
            continue

        parents = sorted(relation_parent_uids(node))
        if not parents:
            print(f"{uid}: no Parent relations, nothing to sign")
            continue

        existing = dict(parse_parent_fp(node.get("PARENT_FP")))
        signed, skipped = [], []
        for parent_uid in parents:
            parent = by_uid.get(parent_uid)
            if parent is None:
                skipped.append((parent_uid, "parent not found in export"))
                continue
            ready, reason = is_ready(parent)
            if not ready:
                skipped.append((parent_uid, reason))
                continue
            existing[parent_uid] = contract_hash(parent)
            signed.append(parent_uid)

        if not signed:
            print(f"{uid}: nothing ready to sign ({len(skipped)} parent(s) still moving)")
            for parent_uid, reason in skipped:
                print(f"  skipped {parent_uid}: {reason}")
            continue

        source = find_source_file(files, uid)
        if source is None:
            print(f"error: {uid} matched in export but no source .sdoc file found under {repo_root}", file=sys.stderr)
            exit_code = 1
            continue

        text = source.read_text()
        new_text = set_parent_fp(text, uid, node_type, format_parent_fp(list(existing.items())))
        source.write_text(new_text)

        print(f"{uid}: signed {len(signed)} parent(s) in {source.relative_to(repo_root)}")
        for parent_uid in signed:
            print(f"  {parent_uid}: {existing[parent_uid]}")
        for parent_uid, reason in skipped:
            print(f"  skipped {parent_uid}: {reason}")

    return exit_code


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("export_json", type=Path)
    parser.add_argument("--repo-root", type=Path, default=Path("."))
    parser.add_argument("uids", nargs="+")
    args = parser.parse_args()

    index = load_index(args.export_json)
    code = accept(index, args.repo_root.resolve(), args.uids)
    if code == 0:
        print("\nRun `strictdoc format .` and re-export before the next fp-check.")
    return code


if __name__ == "__main__":
    sys.exit(main())
