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


def frontmatter_parts(data):
    """Scan one byte boundary for splitting and verification.

    A UTF-8 BOM and either LF or CRLF are accepted. The fenced prefix owns the
    closing fence's line ending. All later bytes, including blank lines,
    belong to the body. Reattachment gives the body one blank separator.
    """
    bom = b"\xef\xbb\xbf"
    start = len(bom) if data.startswith(bom) else 0
    opening = re.match(rb"---(?:\r?\n)", data[start:])
    if opening is None:
        raise ValueError("Markdown is missing its opening frontmatter fence")
    content_start = start + opening.end()
    offset = content_start
    for line in data[content_start:].splitlines(keepends=True):
        offset += len(line)
        if re.fullmatch(rb"---\r?\n", line):
            return data[:offset], data[content_start : offset - len(line)], data[offset:]
    raise ValueError("Markdown is missing its closing frontmatter fence")


def partition(action, path, header):
    try:
        file = pathlib.Path(path)
        header_file = pathlib.Path(header)
        if action == "split":
            data = file.read_bytes()
            prefix, _, body = frontmatter_parts(data)
            header_file.parent.mkdir(parents=True, exist_ok=True)
            header_file.write_bytes(prefix)
            file.write_bytes(body)
        else:
            prefix = header_file.read_bytes()
            body = re.sub(rb"\A(?:[ \t]*\r?\n)+", b"", file.read_bytes())
            newline = b"\r\n" if prefix.endswith(b"\r\n") else b"\n"
            file.write_bytes(prefix + newline + body)
    except (OSError, ValueError) as error:
        print(f"{path}: cannot {action} generated frontmatter: {error}", file=sys.stderr)
        return 1
    return 0


USAGE = "usage: ai-guard-parse-compare TYPE BEFORE AFTER  (TYPE: json, markdown, toml or yaml)"


def parse(kind, text):
    if kind == "json":
        return json.loads(text)
    if kind == "toml":
        return tomllib.loads(text)
    return list(yaml.safe_load_all(text))


def read(kind, data):
    """The data a file carries: Markdown frontmatter bytes, else parsed values."""
    if kind == "markdown":
        prefix, yaml_bytes, _ = frontmatter_parts(data)
        # Byte identity covers syntax and presentation; parsing keeps invalid
        # YAML from passing as unchanged.
        yaml.safe_load(yaml_bytes.decode("utf-8"))
        return prefix
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
        what = "Markdown frontmatter bytes" if kind == "markdown" else f"parsed {kind} values"
        print(f"{after}: {what} differ from {before}", file=sys.stderr)
        return 1
    return 0


def kiro_frontmatter_flow(paths):
    """Reject flow sequences whose brackets occupy different header lines."""
    failed = False
    for path in paths:
        try:
            data = pathlib.Path(path).read_bytes()
            if not data.startswith((b"---\n", b"---\r\n", b"\xef\xbb\xbf---\n", b"\xef\xbb\xbf---\r\n")):
                continue
            _, header, _ = frontmatter_parts(data)
            starts = []
            for token in yaml.scan(header.decode("utf-8")):
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
    if sys.argv[1:2] in (["split"], ["attach"]) and len(sys.argv) == 4:
        sys.exit(partition(*sys.argv[1:]))
    if sys.argv[1:2] == ["compare"] and len(sys.argv) == 5:
        sys.exit(compare(*sys.argv[2:]))
    if sys.argv[1:2] == ["kiro-frontmatter-flow"] and len(sys.argv) >= 2:
        sys.exit(kiro_frontmatter_flow(sys.argv[2:]))
    print(USAGE, file=sys.stderr)
    sys.exit(2)
