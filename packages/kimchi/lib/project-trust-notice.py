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


def holds_readable_file(namespace, excluded=None):
    # An empty or unreadable namespace gives Kimchi nothing to load. Delivered
    # skills are links into the store, so the walk follows links. `excluded` is
    # one user-scope file that does not count.
    return any(
        (path := Path(parent) / name) != excluded and os.access(path, os.R_OK)
        for parent, _, names in os.walk(namespace, followlinks=True)
        for name in names
    )


directory = Path(sys.argv[1]).resolve()
harness = Path(sys.argv[2])
# From $HOME the project harness namespace can be user scope. When it is the
# user harness itself, skip it. When configDir moved the harness and it is only
# the fixed permissions directory, scan it but ignore Kimchi's user
# permissions.json, the one file that is user scope there.
permissions = Path(sys.argv[3]).resolve()
user_harness = harness.resolve()


def holds_project_file(path):
    namespace = directory / path
    resolved = namespace.resolve()
    if resolved == user_harness:
        return False
    return holds_readable_file(namespace, namespace / "permissions.json" if resolved == permissions else None)


if any(map(holds_project_file, sys.argv[4:])) and untrusted(directory, harness):
    print(
        f"warning: Kimchi project files at {directory} are untrusted by "
        f"{harness / 'trust.json'}; unattended sessions ignore them. "
        "Set this directory's trust entry to true (ai.kimchi.projectTrust under Home Manager).",
        file=sys.stderr,
    )
