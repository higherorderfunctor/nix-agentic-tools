# cspell:ignore uids
"""Shared fingerprint logic for fp-check / fp-accept (SLICE-FP-DETECTOR,
docs/plans/strictdoc-tooling/slice-fp-detector.sdoc).

Contract-bearing fields, the placeholder value, and the readiness predicate
all live here so the two CLIs cannot drift against each other. Consumes the
`strictdoc export --formats=json` output directly -- see MECH-FP-CHECK.

Kept underscore-named so both scripts can import it with a plain
`sys.path.insert` regardless of the hyphenated CLI filenames beside it.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

PLACEHOLDER = "0000000"
HASH_LEN = 7

# MECH-FP-CHECK's STATEMENT says only "Excludes RATIONALE and NOTES". PARENT_FP
# is excluded too: it records what a node has signed onto ITS parents, not
# what it promises its own dependents, so accepting an unrelated fingerprint
# must not re-suspect this node's dependents.
#
# This selection is a prototype choice, not a settled answer -- see
# MECH-FP-FIELD-TUNING (docs/plans/strictdoc-tooling/mech-fp-field-tuning.sdoc),
# which is deliberately left for after the Nix option surface in
# DEC-FP-FIELDS-CONFIGURABLE exists. Do not tune this without reading that
# node first.
EXCLUDED_FIELDS = {"RATIONALE", "NOTES", "PARENT_FP"}

# Export-scaffolding keys strictdoc's JSON emits per node that are not sdoc
# fields at all.
STRUCTURAL_KEYS = {"_TOC", "_NODE_TYPE", "UID", "RELATIONS"}

READY_DEPTHS = {"interface-settled", "implemented", "verified"}


def load_index(json_path: Path) -> dict:
    return json.loads(json_path.read_text())


def iter_nodes(index: dict):
    """Yield (document_title, node) for every real node in the export.

    Skips bare TEXT nodes (free-text sections carry no UID and no contract).
    """
    for doc in index["DOCUMENTS"]:
        for node in doc.get("NODES", []):
            if node.get("_NODE_TYPE") == "TEXT":
                continue
            yield doc["TITLE"], node


def build_uid_index(index: dict) -> dict:
    return {node["UID"]: node for _, node in iter_nodes(index) if "UID" in node}


def contract_fields(node: dict) -> dict:
    return {k: v for k, v in node.items() if k not in EXCLUDED_FIELDS and k not in STRUCTURAL_KEYS}


def contract_hash(node: dict) -> str:
    payload = json.dumps(contract_fields(node), sort_keys=True, ensure_ascii=True)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:HASH_LEN]


def parse_parent_fp(raw) -> list:
    """Parse a PARENT_FP field's raw text into (parent_uid, hash) pairs.

    One `UID:hash` entry per line -- see DEC-FINGERPRINT-IN-NODE.
    """
    if not raw:
        return []
    entries = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        uid, _, digest = line.partition(":")
        entries.append((uid.strip(), digest.strip()))
    return entries


def format_parent_fp(entries) -> str:
    return "\n".join(f"{uid}:{digest}" for uid, digest in sorted(entries))


def relation_parent_uids(node: dict) -> set:
    """UIDs this node has a `Parent`-type relation to, of any role.

    `File` relations are excluded on purpose -- they name a filesystem path,
    not a contract-bearing node.
    """
    return {r["VALUE"] for r in node.get("RELATIONS", []) if r.get("TYPE") == "Parent"}


def is_ready(node: dict):
    """MECH-FP-ACCEPT-READINESS: refuse to sign a fingerprint against a
    parent that is still moving.

    A MECHANISM/SLICE/INVARIANT/SPIKE must be interface-settled or better; a
    DECISION must not be STATUS: open. Returns (ready, reason).
    """
    node_type = node.get("_NODE_TYPE")
    if node_type == "DECISION":
        status = node.get("STATUS")
        if status == "open":
            return False, "DECISION is still open"
        return True, ""
    depth = node.get("DEPTH")
    if depth not in READY_DEPTHS:
        return False, f"DEPTH is {depth!r}, needs interface-settled or better"
    return True, ""
