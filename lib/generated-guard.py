#!/usr/bin/env python3
# cspell:ignore keepends
"""Protect generated frontmatter shape and data through formatting.

`compare` is the parseCompare guard; lib/markdown/guards.nix wraps it for both
generated trees and consumer files.
"""

import json
import pathlib
import re
import sys
import tomllib

import yaml
from yaml.tokens import FlowSequenceEndToken, FlowSequenceStartToken


def frontmatter_header(data):
    """Read the fenced YAML header, accepting a UTF-8 BOM and LF or CRLF."""
    bom = b"\xef\xbb\xbf"
    start = len(bom) if data.startswith(bom) else 0
    opening = re.match(rb"---(?:\r?\n)", data[start:])
    if opening is None:
        return None
    content_start = start + opening.end()
    offset = content_start
    for line in data[content_start:].splitlines(keepends=True):
        offset += len(line)
        if re.fullmatch(rb"---\r?\n", line):
            return data[content_start : offset - len(line)].decode("utf-8")
    # An opening fence with no closing fence is a thematic break, not a
    # header; prettier reads it the same way, so the file carries no values.
    return None


USAGE = "usage: ai-guard-parse-compare TYPE BEFORE AFTER  (TYPE: json, markdown, toml or yaml)"


def parse(kind, text):
    if kind == "json":
        return json.loads(text)
    if kind == "toml":
        return tomllib.loads(text)
    return list(yaml.safe_load_all(text))


def read(kind, data):
    """The data a file carries: parsed Markdown frontmatter or structured values."""
    if kind == "markdown":
        header = frontmatter_header(data)
        return None if header is None else yaml.safe_load(header)
    return parse(kind, data.decode("utf-8"))


def compare(kind, before, after):
    """parseCompare: exit 0 when AFTER carries BEFORE's data, 1 when it does not.

    Exit 2 means nothing was compared: an unknown TYPE, an unreadable file, or
    a BEFORE that does not parse as TYPE on its own.
    """
    if kind not in ("json", "markdown", "toml", "yaml"):
        print(USAGE, file=sys.stderr)
        return 2
    try:
        # Read each path once: it may be a pipe from a process substitution.
        before_data = pathlib.Path(before).read_bytes()
        after_data = pathlib.Path(after).read_bytes()
    except OSError as error:
        print(f"{kind} cannot be compared: {error}", file=sys.stderr)
        return 2
    try:
        original = read(kind, before_data)
    except (ValueError, yaml.YAMLError) as error:
        print(f"{before}: {kind} cannot be parsed: {error}", file=sys.stderr)
        print("Nothing was compared: BEFORE must parse on its own.", file=sys.stderr)
        return 2
    try:
        formatted = read(kind, after_data)
    except (ValueError, yaml.YAMLError) as error:
        print(f"{after}: {kind} cannot be parsed: {error}", file=sys.stderr)
        return 1
    if original != formatted:
        what = "parsed Markdown frontmatter values" if kind == "markdown" else f"parsed {kind} values"
        print(f"{after}: {what} differ from {before}", file=sys.stderr)
        return 1
    return 0


def kiro_header_flow(paths):
    """Reject flow sequences whose brackets occupy different header lines."""
    failed = False
    for path in paths:
        try:
            data = pathlib.Path(path).read_bytes()
            header = frontmatter_header(data)
            if header is None:
                continue
            starts = []
            for token in yaml.scan(header):
                if isinstance(token, FlowSequenceStartToken):
                    starts.append(token.start_mark.line)
                elif isinstance(token, FlowSequenceEndToken) and starts:
                    start = starts.pop()
                    if token.end_mark.line > start:
                        print(
                            f"{path}: Kiro frontmatter flow sequence spans multiple lines; "
                            "Kiro silently treats the steering file as always-on context",
                            file=sys.stderr,
                        )
                        failed = True
                        break
        except (OSError, UnicodeDecodeError, ValueError, yaml.YAMLError):
            # This guard owns one measured shape. Other frontmatter faults are
            # outside its contract and remain parseCompare's responsibility.
            continue
    return int(failed)


if __name__ == "__main__":
    if sys.argv[1:2] == ["compare"] and len(sys.argv) == 5:
        sys.exit(compare(*sys.argv[2:]))
    if sys.argv[1:2] == ["kiro-frontmatter-flow"] and len(sys.argv) >= 2:
        sys.exit(kiro_header_flow(sys.argv[2:]))
    print(USAGE, file=sys.stderr)
    sys.exit(2)
