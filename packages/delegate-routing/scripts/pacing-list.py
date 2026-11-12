#!/usr/bin/env python3
"""Inspect a frozen Reader snapshot without launching Readers or ranking routes."""

import argparse
import importlib.util
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("usage_normalize", Path(__file__).with_name("usage-normalize.py"))
normalizer = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = normalizer
spec.loader.exec_module(normalizer)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot", required=True, type=Path)
    parser.add_argument("--now", required=True, help="Explicit UTC ISO instant or integer Unix seconds")
    args = parser.parse_args()
    try:
        now = int(args.now) if args.now.lstrip("-").isdigit() else args.now
        result = normalizer.normalize(json.loads(args.snapshot.read_text()), now)
    except (KeyError, OSError, TypeError, ValueError):
        parser.exit(2, "invalid snapshot or UTC clock\n")
    print(json.dumps(result, allow_nan=False, sort_keys=True, separators=(",", ":")))


if __name__ == "__main__":
    main()
