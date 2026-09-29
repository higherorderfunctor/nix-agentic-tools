#!/usr/bin/env python3
# cspell:ignore keepends
"""Protect generated frontmatter bytes and compare structured data."""

import json
import math
import pathlib
import re
import sys
import tomllib

import yaml


def frontmatter_parts(data, required):
    """Scan one byte boundary for discovery, splitting, and verification.

    A UTF-8 BOM and either LF or CRLF are accepted. The fenced prefix owns the
    closing fence's line ending, if any. All later bytes, including blank lines,
    belong to the body. Reattachment gives a nonempty body one blank separator.
    """
    bom = b"\xef\xbb\xbf"
    start = len(bom) if data.startswith(bom) else 0
    opening = re.match(rb"---(?:\r?\n)", data[start:])
    if opening is None:
        if required:
            raise ValueError("marked Markdown is missing its opening frontmatter fence")
        return None
    content_start = start + opening.end()
    offset = content_start
    for line in data[content_start:].splitlines(keepends=True):
        offset += len(line)
        if re.fullmatch(rb"(?:---|\.\.\.)[ \t]*(?:\r?\n)?", line):
            return data[:offset], data[content_start : offset - len(line)], data[offset:]
    if required:
        raise ValueError("marked Markdown is missing its closing frontmatter fence")
    return None


def partition(action, path, header):
    try:
        file = pathlib.Path(path)
        header_file = pathlib.Path(header)
        if action == "split":
            data = file.read_bytes()
            prefix, _, body = frontmatter_parts(data, required=True)
            header_file.parent.mkdir(parents=True, exist_ok=True)
            header_file.write_bytes(prefix)
            file.write_bytes(body)
        else:
            prefix = header_file.read_bytes()
            body = re.sub(rb"\A(?:[ \t]*\r?\n)+", b"", file.read_bytes())
            if body:
                newline = b"\r\n" if prefix.endswith(b"\r\n") else b"\n"
                separator = newline if prefix.endswith((b"\n", b"\r\n")) else newline * 2
                file.write_bytes(prefix + separator + body)
            else:
                file.write_bytes(prefix)
    except (OSError, ValueError) as error:
        print(f"{path}: cannot {action} generated frontmatter: {error}", file=sys.stderr)
        return 1
    return 0


def reject_non_json_constant(value):
    raise ValueError(f"non-JSON constant: {value}")


def parse(kind, text):
    if kind == "json":
        return json.loads(text, parse_constant=reject_non_json_constant)
    if kind == "toml":
        return tomllib.loads(text)
    if kind == "yaml":
        return list(yaml.safe_load_all(text))
    raise ValueError(f"unsupported generated type: {kind}")


def check_unmarked_frontmatter(path):
    """Independently find YAML mappings behind Markdown fences in built bytes."""
    parts = frontmatter_parts(pathlib.Path(path).read_bytes(), required=False)
    if parts is None:
        return 0
    try:
        value = yaml.safe_load(parts[1].decode("utf-8"))
    except yaml.YAMLError:
        return 0
    if not isinstance(value, dict):
        return 0
    print(f"{path}: generated Markdown has YAML mapping frontmatter without its marker.", file=sys.stderr)
    print("The formatter could change runtime configuration without parseCompare checking it.", file=sys.stderr)
    print("Choose one of three options:", file=sys.stderr)
    print("  1. Route this generator through lib/frontmatter.nix so it marks the file.", file=sys.stderr)
    print("  2. If this is ordinary Markdown, change the opening thematic break or mapping-shaped body.", file=sys.stderr)
    print("  3. Set this file's format to raw if it is consumer-supplied content outside generated-file guards.", file=sys.stderr)
    print("See README.md: Generated-file guards.", file=sys.stderr)
    return 1


def typed(value):
    """Keep scalar types distinct (Python normally considers true == 1)."""
    if isinstance(value, dict):
        return ("dict", frozenset((typed(k), typed(v)) for k, v in value.items()))
    if isinstance(value, list):
        return ("list", tuple(typed(item) for item in value))
    if isinstance(value, float) and math.isnan(value):
        return ("float", "nan")
    return (type(value).__name__, value)


def main(kind, frontmatter, before, after):
    try:
        marked = frontmatter == "true"
        if kind == "markdown" and marked:
            # `before` is the generator's own file, copied ahead of the split and
            # never written again, so a split or reattach defect fails here too,
            # except a defect in `frontmatter_parts`, which split and verify share.
            original_bytes, yaml_bytes, _ = frontmatter_parts(pathlib.Path(before).read_bytes(), required=True)
            formatted_bytes, _, _ = frontmatter_parts(pathlib.Path(after).read_bytes(), required=True)
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
    if typed(original) != typed(formatted):
        print(f"{after}: formatter changed parsed {kind} content", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    if sys.argv[1] == "discover":
        sys.exit(check_unmarked_frontmatter(sys.argv[2]))
    if sys.argv[1] in ("split", "attach"):
        sys.exit(partition(*sys.argv[1:]))
    sys.exit(main(*sys.argv[1:]))
