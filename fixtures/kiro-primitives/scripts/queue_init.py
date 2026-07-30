#!/usr/bin/env python3
"""Materialize a run root from a duration profile.

One file per item, never one shared mutable queue file (invariant L1). A shared
file is the state-rot anti-pattern, and with N continuous claimants a
read-then-write claim on it is a TOCTOU race by construction.

The seed expansion below is deliberately NOT importable from ``queuelib``:
``queue_verify.py`` predicts the same item set from the same profile with
independently written code, and sharing a helper would make that prediction
vacuous -- a bug in the shared expansion would predict exactly the wrong tree
it produced.
"""

import argparse
import json
import os
import shutil
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import queuelib as q  # noqa: E402

# Every subdirectory a run root owns. Named once so --force teardown and
# creation cannot drift apart.
RUN_DIRS = ("admits", "claims", "events", "items", "results")
MARKER = "kiro-primitives-queue"
SCRIPTS_DIR = Path(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_PROFILES_DIR = SCRIPTS_DIR.parent / "queue" / "profiles"


def load_profile(profiles_dir, name):
    path = Path(profiles_dir) / f"{name}.json"
    profile = q.read_json(path)
    if profile is None:
        raise q.QueueError(f"no such profile: {path}")
    for key in ("durations", "id_prefix", "name"):
        if key not in profile:
            raise q.QueueError(f"profile {path} is missing {key!r}")
    if profile["name"] != name:
        raise q.QueueError(f"profile {path} names itself {profile['name']!r}")
    if not profile["durations"]:
        raise q.QueueError(f"profile {path} has an empty durations vector")
    return profile


def expand_seed(profile):
    """Build the seeded item records. Seeded items are at lineage_depth 0."""
    durations = profile["durations"]
    proposers = {}
    for spec in profile.get("proposers", []):
        index = int(spec["seed_index"])
        if not 1 <= index <= len(durations):
            raise q.QueueError(
                f"proposer seed_index {index} is outside 1..{len(durations)}"
            )
        if index in proposers:
            raise q.QueueError(f"duplicate proposer seed_index {index}")
        proposers[index] = {
            "chain": int(spec.get("chain", 1)),
            "duration_units": int(spec.get("duration_units", 1)),
        }

    items = []
    for index, units in enumerate(durations, start=1):
        start = 10 * index
        payload = {"a": start, "b": start + int(units) + 2, "op": "sum_range"}
        items.append(
            {
                "answer": None,
                "attempts": 0,
                "created_at_iso": q.iso(),
                "dead_letter_reason": None,
                "derived_from": None,
                "duration_units": int(units),
                "expected": q.expected_answer(payload),
                "id": f"{profile['id_prefix']}{index:02d}",
                "kind": "seed",
                "lineage_depth": 0,
                "payload": payload,
                "priority": 0,
                "proposes": proposers.get(index),
                "state": "ready",
                "updated_at_iso": q.iso(),
            }
        )
    return items


def prepare_root(root, force):
    root = Path(root)
    if not root.exists():
        root.mkdir(parents=True)
        return root
    if not root.is_dir():
        raise q.QueueError(f"{root} exists and is not a directory")
    if not any(root.iterdir()):
        return root
    existing = q.read_json(q.config_path(root))
    if not force or not isinstance(existing, dict) or existing.get("harness") != MARKER:
        raise q.QueueError(
            f"{root} is not empty. Re-initializing it needs --force AND an "
            f"existing config.json stamped harness={MARKER!r} -- the marker is "
            "what stops a mistyped --root from deleting something real."
        )
    for name in RUN_DIRS:
        shutil.rmtree(root / name, ignore_errors=True)
    for name in ("config.json", "status.json"):
        (root / name).unlink(missing_ok=True)
    return root


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", required=True, help="run root to materialize")
    parser.add_argument("--profile", required=True, help="profile name (no .json)")
    parser.add_argument("--profiles-dir", default=str(DEFAULT_PROFILES_DIR))
    parser.add_argument("--dry-threshold", type=int)
    parser.add_argument("--lease-ttl-sec", type=float)
    parser.add_argument("--max-attempts", type=int)
    parser.add_argument("--max-lineage-depth", type=int)
    parser.add_argument("--unit-ms", type=int, help="milliseconds per duration unit")
    parser.add_argument(
        "--force",
        action="store_true",
        help="re-initialise an existing harness-stamped root",
    )
    args = parser.parse_args(argv)

    profile = load_profile(args.profiles_dir, args.profile)
    items = expand_seed(profile)
    root = prepare_root(args.root, args.force)

    config = dict(q.DEFAULT_CONFIG)
    config.update(profile.get("config", {}))
    for key in (
        "dry_threshold",
        "lease_ttl_sec",
        "max_attempts",
        "max_lineage_depth",
        "unit_ms",
    ):
        value = getattr(args, key)
        if value is not None:
            config[key] = value
    config["harness"] = MARKER
    config["profile"] = profile["name"]
    config["profile_path"] = str(Path(args.profiles_dir) / f"{profile['name']}.json")
    config["seeded_at_iso"] = q.iso()

    for name in RUN_DIRS:
        (root / name).mkdir(parents=True, exist_ok=True)
    q.atomic_write_json(q.config_path(root), config)
    for item in items:
        if not q.create_exclusive_json(q.item_path(root, item["id"]), item):
            raise q.QueueError(f"duplicate seeded item id: {item['id']}")
    q.emit_event(
        root, "queue.initialized", profile=profile["name"], seeded=len(items)
    )

    # Requirement: the status file must exist with {"drained": false} from the
    # start. A MISSING file evaluates to false with only a debug-level log, as
    # does malformed JSON -- so absent is not an error, it is an invisible
    # hang. Computing it here rather than hardcoding it also proves the seeded
    # queue really is not drained.
    status = q.refresh_status(root)
    if status["drained"]:
        raise q.QueueError("freshly seeded queue reports drained -- refusing")

    print(
        json.dumps(
            {
                "config": config,
                "profile": profile["name"],
                "root": str(root),
                "seeded": [item["id"] for item in items],
                "status": status,
            },
            indent=2,
            sort_keys=True,
        )
    )
    return q.EXIT_OK


if __name__ == "__main__":
    sys.exit(q.cli_main("queue_init", main))
