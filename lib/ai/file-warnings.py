"""Observe AI file delivery without taking ownership or deleting user content."""

import json
import os
from pathlib import Path
import sys


def snapshot(state, roots):
    """Remember old upstream declarations before cleanup replaces its ledger."""
    upstream = state / "files.json"
    if not upstream.exists():
        return
    ledger = state / "ai-delivery-observed.json"
    previous = json.loads(ledger.read_text()) if ledger.exists() else {}
    for name in json.loads(upstream.read_text()).get("managedFiles", []):
        for prefix, option in roots.items():
            if name == prefix or name.startswith(prefix + "/"):
                previous.setdefault(name, {"mode": "symlink", "option": option})
    if previous:
        save(ledger, previous)


def save(ledger, entries):
    ledger.parent.mkdir(parents=True, exist_ok=True)
    temporary = ledger.with_suffix(f".{os.getpid()}.tmp")
    temporary.write_text(json.dumps(entries, sort_keys=True))
    temporary.replace(ledger)


def workflows(config_dir):
    settings = config_dir / "settings/cli.json"
    try:
        enabled = json.loads(settings.read_text()).get("chat.enableWorkflows") is True
    except (OSError, ValueError, AttributeError):
        enabled = False
    if not enabled:
        print(
            "WARNING: ai.kiro.unlockedRolloutFeatures includes workflows but "
            f"devenv cannot enable its global setting: {settings} does not set "
            "chat.enableWorkflows=true. Configure ai.kiro.nativeSettings.chat.enableWorkflows "
            "in Home Manager; the project setting is not honored.",
            file=sys.stderr,
        )


def inspect(root, state, desired, current=()):
    ledger = state / "ai-delivery-observed.json"
    previous = json.loads(ledger.read_text()) if ledger.exists() else {}
    retained = {}
    for name, spec in desired.items():
        target = root / name
        if spec["mode"] != "symlink":
            continue
        expected = spec.get("source")
        if not target.is_symlink() or (
            expected is not None and os.readlink(target) != expected
        ):
            print(
                f"WARNING: {spec['option']} is set but devenv did not deliver "
                f"{target}: expected the declared store symlink; check for a "
                "conflicting file, directory, or stale symlink.",
                file=sys.stderr,
            )
    for name, spec in previous.items():
        if name in desired or name in current:
            continue
        target = root / name
        if target.exists() or target.is_symlink():
            print(
                f"WARNING: {spec['option']} was removed but devenv retained "
                f"{target}: cleanup only removes managed store symlinks.",
                file=sys.stderr,
            )
            retained[name] = spec
    if retained or desired or ledger.exists():
        save(ledger, retained | desired)


if __name__ == "__main__":
    try:
        if sys.argv[1] == "workflows":
            workflows(Path(sys.argv[2]))
        elif sys.argv[1] == "snapshot":
            snapshot(Path(sys.argv[2]), json.loads(Path(sys.argv[3]).read_text()))
        else:
            inspect(Path(sys.argv[1]), Path(sys.argv[2]), json.loads(Path(sys.argv[3]).read_text()),
                    json.loads(Path(sys.argv[4]).read_text()) if len(sys.argv) > 4 else [])
    except (AttributeError, KeyError, OSError, TypeError, ValueError) as error:
        print(f"WARNING: ai.*.files delivery inspection failed: {error}", file=sys.stderr)
