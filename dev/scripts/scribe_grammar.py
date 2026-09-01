#!/usr/bin/env python3
# cspell:ignore sgra sdoc
"""Read the option surface out of the .sgra grammar file, with no strictdoc
import and no corpus load (docs/plans/scribe-daemon/).

WHY THIS EXISTS. The scribe command line's flags are derived from the
grammar: one per declared field, each choice list read off that field, the
relation roles off the element. Building that has always required a loaded
graph, which is why `scribe --help` cost a full load and why a client could
not parse anything for itself.

It does not require the CORPUS, only the grammar, and the grammar is a file.
Reading it here was verified to reproduce the loaded grammar exactly -- zero
differences across tags, fields, required, options, roles and prefixes -- so
this is the same source the daemon resolves rather than a second copy
somebody has to keep in agreement.

Shared with docs/sdoc/view/view-check.py, which had the only implementation.
"""

from __future__ import annotations

import re
from pathlib import Path

_SGRA_LINE = re.compile(r"^(?P<indent>\s*)(?P<dash>- )?(?P<key>[A-Z_]+):\s*(?P<value>.*?)\s*$")
_TYPE_RE = re.compile(r"^(?P<kind>[A-Za-z]+)(?:\((?P<options>.*)\))?$")


def parse_sgra(path: Path) -> dict:
    """Read a .sgra grammar into {TYPE: {prefix, fields, roles}}.

    The export types every field as String, so the field kinds and the
    option lists can only come from the grammar file itself.
    """
    grammar: dict = {}
    element = None
    section = None
    item = None
    for raw in path.read_text().splitlines():
        m = _SGRA_LINE.match(raw)
        if not m:
            continue
        dash, key, value = m.group("dash"), m.group("key"), m.group("value")
        if dash and key == "TAG":
            element = {"prefix": "", "fields": [], "roles": []}
            grammar[value] = element
            section = None
            item = None
        elif element is None:
            continue
        elif key == "PREFIX":
            element["prefix"] = value
        elif key in ("FIELDS", "RELATIONS") and not dash:
            section = key
            item = None
        elif dash and section == "FIELDS" and key == "TITLE":
            item = {"name": value, "kind": "String", "options": [], "required": False}
            element["fields"].append(item)
        elif dash and section == "RELATIONS" and key == "TYPE":
            item = {"type": value, "role": None}
            element["roles"].append(item)
        elif item is None:
            continue
        elif section == "FIELDS" and key == "TYPE":
            t = _TYPE_RE.match(value)
            item["kind"] = t.group("kind") if t else value
            options = t.group("options") if t else None
            item["options"] = [o.strip() for o in options.split(",")] if options else []
        elif section == "FIELDS" and key == "REQUIRED":
            item["required"] = value == "True"
        elif section == "RELATIONS" and key == "ROLE":
            item["role"] = value
    return grammar
