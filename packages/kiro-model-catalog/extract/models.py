"""Capture Kiro's public model table and derive soft-enum suggestions offline."""

import argparse
import json
import re
from pathlib import Path


def model_ids(names):
    if not isinstance(names, list):
        raise ValueError("expected model display names")
    ids = []
    for name in names:
        if not isinstance(name, str) or not name:
            raise ValueError("expected nonempty model display names")
        # Decoded display text has no executable or AST representation. Match
        # only its typography; provider names and version semantics are data.
        value = name.lower().replace(" ", "-")
        if not re.fullmatch(r"[a-z0-9]+(?:[-.][a-z0-9]+)*", value) or re.search(
            r"(?<!\d)\.|\.(?!\d)", value
        ):
            raise ValueError(f"invalid model display name {name!r}")
        ids.append(value)
    if len(ids) != len(set(ids)):
        raise ValueError("duplicate or colliding model names")
    if "auto" not in ids or len(ids) < 2:
        raise ValueError("expected Auto and concrete models in the public catalog")
    return sorted(ids)


def capture(document):
    # This source is prose, not code or structured data. Bound the one table
    # before reading cells; a global name regex would collect unrelated prose.
    sections = re.findall(
        r"(?ms)^## Quick comparison\s*\n(.*?)(?=^## |\Z)", document
    )
    if len(sections) != 1:
        raise ValueError("expected exactly one Quick comparison section")
    rows = []
    ended = False
    for line in sections[0].splitlines():
        if line.strip().startswith("|"):
            if ended:
                raise ValueError("interrupted or ambiguous model comparison table")
            rows.append([cell.strip() for cell in line.strip().strip("|").split("|")])
        elif rows:
            ended = True
    if len(rows) < 3 or rows[0].count("Model") != 1:
        raise ValueError("missing model comparison table")
    if len(rows[1]) != len(rows[0]) or not all(
        re.fullmatch(r":?-+:?", cell) for cell in rows[1]
    ):
        raise ValueError("malformed model table header")
    model_column = rows[0].index("Model")
    names = []
    for row in rows[2:]:
        if len(row) != len(rows[0]):
            raise ValueError("malformed model table row")
        name = re.sub(r"<sup>[^<]*</sup>$", "", row[model_column]).strip()
        if name.startswith("**") and name.endswith("**"):
            name = name[2:-2]
        names.append(name)
    model_ids(names)
    return sorted(names)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    args = parser.parse_args()
    try:
        data = args.source.read_text(encoding="utf-8")
        result = {"models": model_ids(capture(data))}
    except (OSError, ValueError) as error:
        parser.exit(1, f"kiro-model-extract: {error}\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
