#!/usr/bin/env python3
# cspell:ignore sgra sdoc
"""Read the daemon's option surface out of the .sgra grammar file.

WHY THIS EXISTS. The daemon serves one compact grammar contract without
requiring every client to import StrictDoc or load the corpus. Its command-line
clients derive one option per declared field and relation role from that reply.

This parser is inside the daemon boundary. Reading it was verified to reproduce
the loaded grammar exactly across tags, fields, requiredness, options, roles,
and prefixes. Consumers receive its scribe-grammar/1 result over RPC rather than
importing this module or opening the file themselves.
"""

from __future__ import annotations

import re
from pathlib import Path

_SGRA_LINE = re.compile(
    r"^(?P<indent>\s*)(?P<dash>- )?(?P<key>[A-Z_]+):\s*(?P<value>.*?)\s*$"
)
_TYPE_RE = re.compile(r"^(?P<kind>[A-Za-z]+)(?:\((?P<options>.*)\))?$")


def parse_sgra(path: Path) -> dict:
    """Read a .sgra grammar into ``{TYPE: {prefix, fields, roles}}``."""
    grammar: dict = {}
    element = None
    section = None
    item = None
    for raw in path.read_text().splitlines():
        match = _SGRA_LINE.match(raw)
        if not match:
            continue
        dash = match.group("dash")
        key = match.group("key")
        value = match.group("value")
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
            item = {
                "name": value,
                "kind": "String",
                "options": [],
                "required": False,
            }
            element["fields"].append(item)
        elif dash and section == "RELATIONS" and key == "TYPE":
            item = {"type": value, "role": None}
            element["roles"].append(item)
        elif item is None:
            continue
        elif section == "FIELDS" and key == "TYPE":
            field_type = _TYPE_RE.match(value)
            item["kind"] = field_type.group("kind") if field_type else value
            options = field_type.group("options") if field_type else None
            item["options"] = (
                [option.strip() for option in options.split(",")] if options else []
            )
        elif section == "FIELDS" and key == "REQUIRED":
            item["required"] = value == "True"
        elif section == "RELATIONS" and key == "ROLE":
            item["role"] = value
    return grammar
