"""Warn when persisted Kimchi trust will discard delivered project files."""
# cspell:ignore followlinks

import json
import os
import sys
from pathlib import Path


def read_json(path):
    try:
        with path.open(encoding="utf-8-sig") as stream:
            value = json.load(stream)
        return value if isinstance(value, dict) else None
    except (OSError, ValueError):
        return None


def untrusted(directory, harness):
    trust = read_json(harness / "trust.json")
    # A missing/unreadable user trust store is a normal first-run case.
    if trust is None or any(value is not None and not isinstance(value, bool) for value in trust.values()):
        return False
    for parent in (directory, *directory.parents):
        decision = trust.get(str(parent))
        if isinstance(decision, bool):
            return not decision
    settings = read_json(harness / "settings.json")
    # With no persisted decision, only readable user settings can establish
    # the default; project settings cannot grant their own trust.
    return settings is not None and settings.get("defaultProjectTrust") != "always"


def holds_readable_file(namespace):
    # An empty or unreadable namespace gives Kimchi nothing to load. Delivered
    # skills are links into the store, so the walk follows links.
    return any(os.access(Path(parent) / name, os.R_OK) for parent, _, names in os.walk(namespace, followlinks=True) for name in names)


directory = Path(sys.argv[1]).resolve()
harness = Path(sys.argv[2])
# From $HOME the project harness namespace is the user harness itself.
paths = [directory / path for path in sys.argv[3:] if (directory / path).resolve() != harness.resolve()]
if any(map(holds_readable_file, paths)) and untrusted(directory, harness):
    print(
        f"warning: Kimchi project files at {directory} are untrusted by "
        f"{harness / 'trust.json'}; unattended sessions ignore them. "
        "Set this directory's trust entry to true (ai.kimchi.projectTrust under Home Manager).",
        file=sys.stderr,
    )
