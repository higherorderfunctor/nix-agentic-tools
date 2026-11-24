# pyright: strict
"""Owner checks call this script with a fixture directory, an importable Reader entry and a case."""

from collections.abc import Sequence
from pathlib import Path
import sys

# Isolated Python omits the script directory, which holds the shared suite.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from suite import IncompletePair, Pair, differences


def main(args: Sequence[str]) -> int:
    """Run the selected cases and report a safe diagnostic for each difference."""
    if len(args) not in (2, 3):
        print("usage: run.py <pair directory> <module>:<function> [all | <scenario>/<transport>]", file=sys.stderr)
        return 1
    try:
        pair = Pair.read(Path(args[0]))
        selector = args[2] if len(args) == 3 else "all"
        cases = list(pair.cases.values()) if selector == "all" else [pair.cases[selector]]
        errors = [error for case in cases for error in differences(pair.inputs, case, args[1])]
    except IncompletePair as error:
        print(error, file=sys.stderr)
        return 1
    except (AttributeError, ImportError, KeyError, OSError, ValueError):
        print("invalid fixture, Reader entry or case selection", file=sys.stderr)
        return 1
    for error in errors:
        print(error, file=sys.stderr)
    return int(bool(errors))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
