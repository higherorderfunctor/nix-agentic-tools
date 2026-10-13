"""Validate public model documentation and update its independent source pin."""

import argparse
import base64
import hashlib
import re
import sys
from pathlib import Path

from models import capture


def refresh(recipe, document, snapshot_date):
    data = document.read_bytes()
    capture(data.decode("utf-8"))
    digest = "sha256-" + base64.b64encode(hashlib.sha256(data).digest()).decode("ascii")
    text = recipe.read_text(encoding="utf-8")
    fields = {}
    for key in ("hash", "snapshotDate"):
        matches = re.findall(rf'^  {key} = "([^"\n]+)";$', text, re.MULTILINE)
        if len(matches) != 1:
            raise ValueError(f"expected exactly one recipe field: {key}")
        fields[key] = matches[0]
    if digest == fields["hash"]:
        print("kiro-model-catalog: documentation is unchanged", file=sys.stderr)
        return False
    for key, value in (("hash", digest), ("snapshotDate", snapshot_date)):
        text = text.replace(f'{key} = "{fields[key]}";', f'{key} = "{value}";')
    recipe.write_text(text, encoding="utf-8")
    print(f"kiro-model-catalog: {fields['snapshotDate']} -> {snapshot_date}", file=sys.stderr)
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recipe", type=Path)
    parser.add_argument("document", type=Path)
    parser.add_argument("snapshot_date")
    args = parser.parse_args()
    print("true" if refresh(args.recipe, args.document, args.snapshot_date) else "false")


if __name__ == "__main__":
    main()
