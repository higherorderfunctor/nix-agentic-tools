#!/usr/bin/env python3
"""Inspect allowance observations; bank, reset, credit and cost support is incomplete."""

import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("usage_normalize", Path(__file__).with_name("usage-normalize.py"))
normalizer = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = normalizer
spec.loader.exec_module(normalizer)


def collect(manifest, now, reader_shell):
    """Run each distinct registered command once; never emit transport output."""
    captures = {}
    readers = {}
    for pool, registration in sorted(manifest["pools"].items()):
        command = registration["command"]
        if command is None:
            continue
        if command not in captures:
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
            captures[command] = {**capture, "finishedAt": now}
        readers[pool] = captures[command]
    return {**manifest, "readers": readers}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sources = parser.add_mutually_exclusive_group(required=False)
    sources.add_argument("--snapshot", type=Path, help="Offline saved captures; no Reader is executed")
    sources.add_argument("--manifest", type=Path, help="Catalog-bound registrations")
    parser.add_argument("--default-manifest", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--runtime", help="Runtime whose configured pool reach to inspect")
    parser.add_argument("--reader-shell", default="/bin/bash", help=argparse.SUPPRESS)
    parser.add_argument("--now", required=True, help="Explicit UTC ISO instant or integer Unix seconds")
    args = parser.parse_args()
    try:
        now = int(args.now) if args.now.lstrip("-").isdigit() else args.now
        now = normalizer.utc(now)
        if args.snapshot:
            snapshot = json.loads(args.snapshot.read_text())
        else:
            manifests = json.loads((args.manifest or args.default_manifest).read_text())
            if args.runtime not in manifests:
                raise ValueError("unknown-runtime")
            snapshot = collect(manifests[args.runtime], now, args.reader_shell)
        result = normalizer.normalize(snapshot, now)
        if args.snapshot is None:
            result["routes"] = snapshot["routes"]
    except (AttributeError, KeyError, OSError, TypeError, ValueError):
        parser.exit(2, "invalid snapshot, runtime registration or UTC clock\n")
    print(json.dumps(result, allow_nan=False, sort_keys=True, separators=(",", ":")))


if __name__ == "__main__":
    main()
