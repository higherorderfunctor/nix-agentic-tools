"""Minimal in-place field editor for .sdoc source files.

Does exactly one job: locating a node by UID in its source file and
rewriting its PARENT_FP field. This is NOT a general sdoc writer -- per the
sdoc skill's hard rules, `strictdoc manage new` scaffolds new nodes and
`strictdoc format` canonicalizes whitespace; this only ever touches one
already-declared optional field on an existing node, which fp-accept is the
sole caller of (DEC-FINGERPRINT-IN-NODE: "the only thing that writes them").

Field-block boundaries are found structurally (tag lines, field-name lines,
`>>>`/`<<<` markers) rather than by splitting on blank lines, because a
multiline field's own prose can contain blank lines (paragraph breaks) --
see e.g. SPIKE-SGRA-PARSE's NOTES in spike-sgra-parse.sdoc.
"""

from __future__ import annotations

import re

NODE_TAG_RE = re.compile(r"^\[(DECISION|MECHANISM|SLICE|INVARIANT|SPIKE)\]\s*$")
UID_LINE_RE = re.compile(r"^UID:\s*(\S+)\s*$")
FIELD_START_RE = re.compile(r"^([A-Z][A-Z_]*):\s*(.*)$")

# Field order per grammar (docs/sdoc/grammar.sgra), PARENT_FP-bearing types
# only -- DECISION carries no PARENT_FP field at all.
FIELD_ORDER = {
    "MECHANISM": ["UID", "TITLE", "DEPTH", "AUTHORED_BY", "STATEMENT", "RATIONALE", "PARENT_FP", "NOTES"],
    "SLICE": ["UID", "TITLE", "DEPTH", "AUTHORED_BY", "STATEMENT", "RATIONALE", "PARENT_FP", "NOTES"],
    "INVARIANT": ["UID", "TITLE", "DEPTH", "AUTHORED_BY", "STATEMENT", "RATIONALE", "PARENT_FP", "NOTES"],
    "SPIKE": ["UID", "TITLE", "DEPTH", "AUTHORED_BY", "STATUS", "RETIRES_ON", "STATEMENT", "RATIONALE", "PARENT_FP", "NOTES"],
}


def find_node_block(lines, uid: str):
    """Return the [start, end) line-index range of the node whose UID matches."""
    tag_starts = [i for i, l in enumerate(lines) if NODE_TAG_RE.match(l)]
    for idx, start in enumerate(tag_starts):
        end = tag_starts[idx + 1] if idx + 1 < len(tag_starts) else len(lines)
        for i in range(start, end):
            m = UID_LINE_RE.match(lines[i])
            if m and m.group(1) == uid:
                return start, end
    return None


def find_field_span(lines, start: int, end: int, field: str):
    """Return [line_start, line_end) for `field` within lines[start:end],
    including its `>>>`/`<<<` block when the field is multiline."""
    i = start
    while i < end:
        m = FIELD_START_RE.match(lines[i])
        if m and m.group(1) == field:
            if m.group(2).strip() == ">>>":
                j = i + 1
                while j < end and lines[j].rstrip() != "<<<":
                    j += 1
                return i, j + 1
            return i, i + 1
        i += 1
    return None


def render_field(name: str, value: str):
    if "\n" in value:
        return [f"{name}: >>>", *value.splitlines(), "<<<"]
    return [f"{name}: {value}"]


def set_parent_fp(text: str, uid: str, node_type: str, value: str) -> str:
    """Return `text` with `uid`'s PARENT_FP field set to `value` (already
    `format_parent_fp`-rendered). Inserts the field in grammar order if it
    was absent; replaces it whole (including its `>>>`/`<<<` block) if
    present."""
    if node_type not in FIELD_ORDER:
        raise ValueError(f"{node_type} carries no PARENT_FP field")

    trailing_newline = text.endswith("\n")
    lines = text.splitlines()
    block = find_node_block(lines, uid)
    if block is None:
        raise ValueError(f"node {uid} not found in this file")
    start, end = block

    new_field_lines = render_field("PARENT_FP", value)
    existing = find_field_span(lines, start, end, "PARENT_FP")
    if existing:
        field_start, field_end = existing
        lines[field_start:field_end] = new_field_lines
    else:
        order = FIELD_ORDER[node_type]
        pfp_idx = order.index("PARENT_FP")
        insert_at = end
        for prior_field in reversed(order[:pfp_idx]):
            span = find_field_span(lines, start, end, prior_field)
            if span:
                insert_at = span[1]
                break
        else:
            # No prior field found (should not happen -- STATEMENT is
            # required) -- fall back to the end of the block, trimmed past
            # any blank separator line(s) before the next node's tag.
            while insert_at > start and lines[insert_at - 1].strip() == "":
                insert_at -= 1
        lines[insert_at:insert_at] = new_field_lines

    return "\n".join(lines) + ("\n" if trailing_newline else "")
