#!/usr/bin/env python3
# cspell:ignore keepends
"""Protect generated frontmatter bytes and compare structured data."""

import json
import pathlib
import re
import sys
import tomllib

import yaml


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
        raise ValueError("marked Markdown is missing its opening frontmatter fence")
    content_start = start + opening.end()
    offset = content_start
    for line in data[content_start:].splitlines(keepends=True):
        offset += len(line)
        if re.fullmatch(rb"---\r?\n", line):
            return data[:offset], data[content_start : offset - len(line)], data[offset:]
    raise ValueError("marked Markdown is missing its closing frontmatter fence")


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


def parse(kind, text):
    if kind == "json":
        return json.loads(text)
    if kind == "toml":
        return tomllib.loads(text)
    if kind == "yaml":
        return list(yaml.safe_load_all(text))
    raise ValueError(f"unsupported generated type: {kind}")


def main(kind, frontmatter, before, after):
    try:
        marked = frontmatter == "true"
        if kind == "markdown" and marked:
            # `before` is the generator's immutable source file, so a split or
            # reattach defect fails here too,
            # except a defect in `frontmatter_parts`, which split and verify share.
            original_bytes, yaml_bytes, _ = frontmatter_parts(pathlib.Path(before).read_bytes())
            formatted_bytes, _, _ = frontmatter_parts(pathlib.Path(after).read_bytes())
            if original_bytes != formatted_bytes:
                print(f"{after}: installed Markdown frontmatter bytes differ from the generator bytes", file=sys.stderr)
                print("The formatter or the split/reattach step changed them.", file=sys.stderr)
                return 1
            # Byte identity covers syntax and presentation; parse the original
            # once to keep invalid generated YAML from reaching consumers.
            yaml.safe_load(yaml_bytes.decode("utf-8"))
            return 0
        if kind == "markdown":
            return 0
        original = parse(kind, pathlib.Path(before).read_text(encoding="utf-8"))
        formatted = parse(kind, pathlib.Path(after).read_text(encoding="utf-8"))
    except (OSError, ValueError, yaml.YAMLError) as error:
        print(f"{after}: generated {kind} cannot be parsed: {error}", file=sys.stderr)
        return 1
    if original != formatted:
        print(f"{after}: formatter changed parsed {kind} content", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    if sys.argv[1] in ("split", "attach"):
        sys.exit(partition(*sys.argv[1:]))
    sys.exit(main(*sys.argv[1:]))
