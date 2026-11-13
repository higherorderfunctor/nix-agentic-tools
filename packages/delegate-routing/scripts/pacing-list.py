"""Offline allowance preview CLI; the explicit clock makes replay reproducible."""

import argparse
import importlib.util
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("usage_normalize", Path(__file__).with_name("usage-normalize.py"))
normalizer = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = normalizer
SPEC.loader.exec_module(normalizer)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot", required=True)
    parser.add_argument("--now", required=True)
    args = parser.parse_args()
    try:
        snapshot = json.loads(Path(args.snapshot).read_text())
        result = normalizer.normalize(snapshot, args.now)
    except (OSError, ValueError, TypeError, OverflowError, RecursionError):
        # Neither paths, timestamps nor JSON/parser exception text are diagnostics.
        print(json.dumps({"reason": "invalid-input"}), file=sys.stderr)
        return 2
    print(json.dumps(result, sort_keys=True, indent=2, allow_nan=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
