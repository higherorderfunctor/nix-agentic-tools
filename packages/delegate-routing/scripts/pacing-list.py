"""Allowance preview from registered Readers or transport-free saved captures."""

import argparse
import importlib.util
import json
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


def collect(manifest, now, reader_shell):
    """Share each command's bounded attempt and execution retry across registrations."""
    captures, readers = {}, {}
    for pool, registration in sorted(manifest["pools"].items()):
        command = registration["command"]
        if command is None:
            continue
        if command not in captures:
            for attempt in range(2):
                try:
                    process = subprocess.run(
                        [reader_shell, "-c", "set -euETo pipefail\nshopt -s inherit_errexit 2>/dev/null || :\n" + command.replace("<now-ms>", str(now * 1000))],
                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=30,
                    )
                    capture = {"exit": process.returncode, "stdout": process.stdout.decode("utf-8", errors="replace")}
                except subprocess.TimeoutExpired:
                    capture = {"exit": 124, "data": {"diagnostic": {"reason": "timeout"}}}
                except OSError:
                    capture = {"exit": 127, "data": {"diagnostic": {"reason": "refused"}}}
                # Successful malformed output belongs to normalization, never retry.
                if capture["exit"] == 0 or attempt == 1:
                    break
                time.sleep(2)
            captures[command] = {**capture, "finishedAt": now}
        readers[pool] = captures[command]
    return {**manifest, "readers": readers}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sources = parser.add_mutually_exclusive_group()
    sources.add_argument("--snapshot", type=Path)
    sources.add_argument("--manifest", type=Path)
    parser.add_argument("--default-manifest", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--runtime")
    parser.add_argument("--reader-shell", default="/bin/bash", help=argparse.SUPPRESS)
    parser.add_argument("--now", required=True)
    args = parser.parse_args()
    try:
        now = normalizer.utc(args.now)
        if args.snapshot is not None:
            snapshot = json.loads(args.snapshot.read_text())
        else:
            manifests = json.loads((args.manifest or args.default_manifest).read_text())
            manifest = manifests[args.runtime]
            # Validate scopes before any configured transport executes.
            normalizer.normalize({**manifest, "readers": {}}, now)
            snapshot = collect(manifest, now, args.reader_shell)
        result = normalizer.normalize(snapshot, now)
    except (AttributeError, KeyError, OSError, ValueError, TypeError, OverflowError, RecursionError):
        # Neither paths, timestamps nor JSON/parser exception text are diagnostics.
        print(json.dumps({"reason": "invalid-input"}), file=sys.stderr)
        return 2
    print(json.dumps(result, sort_keys=True, indent=2, allow_nan=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
