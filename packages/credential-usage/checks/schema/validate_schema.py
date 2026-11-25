"""Validate the documented bytes and the fill authors' literal public results against the shipped schema."""

import json
from pathlib import Path
import sys

from jsonschema import Draft202012Validator

CHECKS = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(CHECKS / "contract"), str(CHECKS / "conformance")]

from suite import Pair
from test_envelope import documented_example


def main(schema: Path, pairs: list[Path]) -> None:
    """Behavior 3. Detect a published schema that rejects a valid example or golden result."""
    published = json.loads(schema.read_bytes())
    Draft202012Validator.check_schema(published)
    validator = Draft202012Validator(published, format_checker=Draft202012Validator.FORMAT_CHECKER)
    validator.validate(json.loads(documented_example()))
    for directory in pairs:
        results = {
            case.name: case.expected.result for case in Pair.read(directory).cases.values()
            if case.expected.result.keys() != {"failed"}
        }
        if not results:
            raise ValueError(f"{directory} contains no successful golden results")
        for name, result in results.items():
            if error := next(validator.iter_errors(result), None):
                raise ValueError(f"{directory}/{name}: {error.json_path}: {error.message}")
        print(f"{directory}: validated {len(results)} golden results")


if __name__ == "__main__":
    main(Path(sys.argv[1]), list(map(Path, sys.argv[2:])))
