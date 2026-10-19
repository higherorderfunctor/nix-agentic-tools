"""Report AI file delivery devenv did not finish; never owns or deletes."""

import json
import os
from pathlib import Path
import sys

# Shared with the observer this replaced, so its remembered paths carry over.
LEDGER = "ai-delivery-observed.json"


def load(path):
    return json.loads(path.read_text()) if path.exists() else {}


def save(ledger, entries):
    ledger.parent.mkdir(parents=True, exist_ok=True)
    temporary = ledger.with_suffix(f".{os.getpid()}.tmp")
    temporary.write_text(json.dumps(entries, sort_keys=True))
    temporary.replace(ledger)


def snapshot(state, manifest):
    """Remember devenv's previous links, for AI-owned paths only, before cleanup rewrites its list."""
    upstream = state / "files.json"
    if not upstream.exists():
        return
    ledger = state / LEDGER
    previous = load(ledger)
    for name in load(upstream).get("managedFiles", []):
        option = manifest["owned"].get(name)
        if option is not None:
            previous.setdefault(name, {"option": option})
    if previous:
        save(ledger, previous)


def inspect(root, state, manifest):
    ledger = state / LEDGER
    previous = load(ledger)
    links = manifest["links"]
    current = set(manifest["current"])
    for name, spec in links.items():
        target = root / name
        if not target.is_symlink() or os.readlink(target) != spec["source"]:
            print(
                f"WARNING: {spec['option']} is set but devenv did not deliver "
                f"{target}: expected the declared store symlink; check for a "
                "conflicting file, directory, or stale symlink.",
                file=sys.stderr,
            )
    retained = {}
    for name, spec in previous.items():
        if name in links or name in current:
            continue
        target = root / name
        # Devenv only ever wrote a store link here. Anything else on disk is
        # the user's, taken over on purpose, and is forgotten without a word.
        if target.is_symlink() and os.readlink(target).startswith("/nix/store/"):
            print(
                f"WARNING: {spec['option']} was removed but devenv left its "
                f"store link at {target}: remove the link by hand.",
                file=sys.stderr,
            )
            retained[name] = spec
    if retained or links or ledger.exists():
        save(ledger, retained | links)


if __name__ == "__main__":
    phase, root, state, manifest = sys.argv[1:]
    try:
        document = load(Path(manifest))
        if phase == "snapshot":
            snapshot(Path(state), document)
        else:
            inspect(Path(root), Path(state), document)
    # An observer never blocks the shell: a malformed ledger is reported.
    except (AttributeError, KeyError, OSError, TypeError, ValueError) as error:
        print(f"WARNING: AI file delivery inspection failed: {error}", file=sys.stderr)
