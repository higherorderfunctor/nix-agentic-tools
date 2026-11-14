"""Allowance preview from registered Readers or transport-free saved captures."""

import argparse
import importlib.util
import json
import runpy
from pathlib import Path
import sys
import subprocess
import time

sys.dont_write_bytecode = True
# Locate the hyphenated sibling without relying on the caller's import path.
SPEC = importlib.util.spec_from_file_location("usage_normalize", Path(__file__).with_name("usage-normalize.py"))
# Register the module before execution so dataclass annotations can resolve it.
normalizer = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = normalizer
SPEC.loader.exec_module(normalizer)

# Load the pure engine beside the source CLI, including under isolated Python.
rank = runpy.run_path(str(Path(__file__).with_name("pacing.py")))["rank"]


# Reuse the routing helper's retry, timeout and process-group cleanup policy.
SPEC = importlib.util.spec_from_file_location("routing_plan", Path(__file__).with_name("delegate-routing-plan.py"))
planner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(planner)


def collect(manifest, now, reader_shell):
    """Retain raw captures while the shared collector owns command execution."""
    captures = {}

    def capture(argv, **kwargs):
        try:
            process = planner.run_reader(argv, **kwargs)
        except (OSError, subprocess.TimeoutExpired, UnicodeError) as error:
            # The normalizer owns the fixed nonzero-exit diagnostic; no payload escapes.
            status = 65 if isinstance(error, UnicodeError) else 124 if isinstance(error, subprocess.TimeoutExpired) else 127
            process = subprocess.CompletedProcess(argv, status, "")
        captures[command] = {"exit": process.returncode, "finishedAt": int(time.time()), "stdout": process.stdout}
        # Only the preview normalizer parses these envelopes. The shared helper
        # needs the status for retry; its routing measurement is discarded.
        return subprocess.CompletedProcess(argv, process.returncode, "{}")

    readers = [{"command": registration["command"].replace("<now-ms>", str(now * 1000)), "name": pool}
               for pool, registration in sorted(manifest["pools"].items()) if registration["command"] is not None]
    for reader in readers:
        command = reader["command"]
        if command not in captures:
            planner.collect([reader], now, reader_shell, run=capture)
    return {**manifest, "readers": {reader["name"]: captures[reader["command"]] for reader in readers}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sources = parser.add_mutually_exclusive_group()
    sources.add_argument("--snapshot", type=Path)
    sources.add_argument("--manifest", type=Path)
    parser.add_argument("--default-manifest", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--runtime")
    parser.add_argument("--reader-shell", default="/bin/bash", help=argparse.SUPPRESS)
    parser.add_argument("--now", help="Explicit UTC clock for snapshot replay only")
    args = parser.parse_args()
    try:
        if args.snapshot is not None and args.now is None:
            parser.error("--snapshot requires --now")
        if args.snapshot is None and args.now is not None:
            parser.error("--now is only for --snapshot replay")
        now = normalizer.utc(args.now) if args.now is not None else int(time.time())
        if args.snapshot is not None:
            snapshot = json.loads(args.snapshot.read_text())
        else:
            manifests = json.loads((args.manifest or args.default_manifest).read_text())
            manifest = manifests[args.runtime]
            # Validate scopes before any configured transport executes.
            normalizer.normalize({**manifest, "readers": {}}, now)
            snapshot = collect(manifest, now, args.reader_shell)
            now = int(time.time())
        result = rank(normalizer.normalize(snapshot, now), snapshot.get("policy"))
    except (AttributeError, KeyError, OSError, ValueError, TypeError, OverflowError, RecursionError):
        # Neither paths, timestamps nor JSON/parser exception text are diagnostics.
        print(json.dumps({"reason": "invalid-input"}), file=sys.stderr)
        return 2
    print(json.dumps(result, sort_keys=True, indent=2, allow_nan=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
