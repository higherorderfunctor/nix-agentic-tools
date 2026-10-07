"""Print named fields of a harness case run, so a case-table excerpt can be read off stdout.

Usage: python3 show.py <case> <name> [<name> ...]   (reads $CLAUDE_PROBE_WORK/out/<case>/)
A name is a `summary.json` key (looked up under `data`, then at the top level) or a
JSON file in the case's out dir (`driver-log.json`). A dict or list value prints one
line per entry, `<case> <name>.<key>: <json>` or `<case> <name>[<i>]: <json>`;
strings holding JSON are decoded first, so nested tool results print as objects;
other strings print raw with newlines escaped.
"""
import json
import os
import pathlib
import sys

WORK = pathlib.Path(os.environ.get("CLAUDE_PROBE_WORK", ""))


def decode(value):
    if isinstance(value, str) and value[:1] in "{[":
        try:
            return decode(json.loads(value))
        except ValueError:
            return value
    if isinstance(value, dict):
        return {k: decode(v) for k, v in value.items()}
    if isinstance(value, list):
        return [decode(v) for v in value]
    return value


def render(value):
    """One line per entry: a plain string prints as-is with newlines escaped, anything else as JSON."""
    return value.replace("\n", "\\n") if isinstance(value, str) else json.dumps(value)


if len(sys.argv) < 3 or not WORK.name:
    sys.exit(__doc__ + "\nSet CLAUDE_PROBE_WORK to the harness work dir.")
case, names = sys.argv[1], sys.argv[2:]
out = WORK / "out" / case
summary = json.loads((out / "summary.json").read_text())
for name in names:
    if (out / name).is_file():
        value = json.loads((out / name).read_text())
    elif name in summary["data"]:
        value = summary["data"][name]
    elif name in summary:
        value = summary[name]
    else:
        sys.exit(f"{case}: no field or file {name!r}")
    value = decode(value)
    entries = (value.items() if isinstance(value, dict)
               else ((f"[{i}]", v) for i, v in enumerate(value)) if isinstance(value, list) else [("", value)])
    for key, item in entries:
        sep = "" if not key or key.startswith("[") else "."
        print(f"{case} {name}{sep}{key}: {render(item)}")
