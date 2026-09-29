#!/usr/bin/env python3
"""Compare parsed generated data before and after formatting."""

import json
import math
import pathlib
import sys
import tomllib

import yaml


def reject_non_json_constant(value):
    raise ValueError(f"non-JSON constant: {value}")


def parse(kind, text):
    if kind == "json":
        return json.loads(text, parse_constant=reject_non_json_constant)
    if kind == "toml":
        return tomllib.loads(text)
    if kind == "yaml":
        return list(yaml.safe_load_all(text))
    if kind == "markdown":
        if not text.startswith("---\n"):
            return (False, None)
        end = text.find("\n---\n", 3)
        if end < 0:
            raise ValueError("unclosed Markdown YAML frontmatter")
        return (True, yaml.safe_load(text[4:end]))
    raise ValueError(f"unsupported generated type: {kind}")


def typed(value):
    """Keep scalar types distinct (Python normally considers true == 1)."""
    if isinstance(value, dict):
        return ("dict", frozenset((typed(k), typed(v)) for k, v in value.items()))
    if isinstance(value, list):
        return ("list", tuple(typed(item) for item in value))
    if isinstance(value, tuple):
        return ("tuple", tuple(typed(item) for item in value))
    if isinstance(value, float) and math.isnan(value):
        return ("float", "nan")
    return (type(value).__name__, value)


def main(kind, before, after):
    try:
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
    sys.exit(main(*sys.argv[1:]))
