# pyright: strict
"""Owner checks call this script with a fixture directory, an importable Reader entry and a case."""

from collections.abc import Sequence
from pathlib import Path
import sys
import unittest

# Isolated Python omits the script directory, which holds the shared suite.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from suite import conformance


def main(args: Sequence[str]) -> int:
    """Run the selected cases and report each failed comparison."""
    if len(args) not in (2, 3):
        print("usage: run.py <pair directory> <module>:<function> [all | <scenario>/<transport>]", file=sys.stderr)
        return 2
    try:
        tests = conformance(Path(args[0]), args[1], args[2] if len(args) == 3 else "all")
    except (OSError, ValueError, KeyError) as error:
        print(f"invalid fixture or case selection: {error!r}", file=sys.stderr)
        return 2
    return int(not unittest.TextTestRunner(verbosity=2).run(tests).wasSuccessful())


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
