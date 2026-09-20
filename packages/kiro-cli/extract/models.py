"""Capture Kiro's public model table and derive soft-enum suggestions offline."""

import argparse
import json
import re
from pathlib import Path

SOURCE = "https://kiro.dev/docs/models.md"
# Kiro 2.22.1's unauthenticated _kiro/workflow/listRecipes contains this
# additional ID in feature-pipeline and semantic-review-multi-model. It does
# not establish that the public Fable 5.1 display and Fable 5 are aliases.
ADDITIONAL_IDS = {"claude-fable-5.1": ["claude-fable-5"]}
MODEL_SHAPE = re.compile(
    r"auto|claude-[a-z]+-\d+(?:\.\d+)*|gpt-\d+(?:\.\d+)*(?:-[a-z]+)?|"
    r"deepseek-\d+(?:\.\d+)*|glm-\d+(?:\.\d+)*|"
    r"minimax-m\d+(?:\.\d+)*|qwen\d+-coder-[a-z0-9]+"
)


def model_ids(catalog):
    if not isinstance(catalog, dict) or catalog.get("source") != SOURCE:
        raise ValueError("expected a public Kiro model-table snapshot")
    names = catalog.get("models")
    if not isinstance(names, list) or not all(isinstance(n, str) for n in names):
        raise ValueError("expected model display names")
    ids = []
    for name in names:
        value = name.lower().replace(" ", "-")
        # The documented 4.0 label uses the CLI's original 4 ID.
        if value == "claude-sonnet-4.0":
            value = "claude-sonnet-4"
        if not MODEL_SHAPE.fullmatch(value):
            raise ValueError(f"unrecognized model name {name!r}; review its CLI spelling")
        ids.append(value)
    if len(ids) != len(set(ids)):
        raise ValueError("duplicate or colliding model names")
    if "auto" not in ids or len(ids) < 2:
        raise ValueError("expected Auto and concrete models in the public catalog")
    additional = {extra for value in ids for extra in ADDITIONAL_IDS.get(value, [])}
    return sorted(set(ids) | additional)


def capture(document):
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
    if len(rows) < 3 or rows[0][0] != "Model":
        raise ValueError("missing model comparison table")
    if len(rows[1]) != len(rows[0]) or not all(
        re.fullmatch(r":?-+:?", cell) for cell in rows[1]
    ):
        raise ValueError("malformed model table header")
    names = []
    for row in rows[2:]:
        if len(row) != len(rows[0]):
            raise ValueError("malformed model table row")
        name = re.sub(r"<sup>[^<]*</sup>$", "", row[0]).strip()
        if name.startswith("**") and name.endswith("**"):
            name = name[2:-2]
        names.append(name)
    catalog = {"models": sorted(names), "source": SOURCE}
    model_ids(catalog)
    return catalog


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["capture", "ids"])
    parser.add_argument("source", type=Path)
    args = parser.parse_args()
    try:
        data = args.source.read_text(encoding="utf-8")
        result = capture(data) if args.action == "capture" else model_ids(json.loads(data))
    except (OSError, ValueError) as error:
        parser.exit(1, f"kiro-model-extract: {error}\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
