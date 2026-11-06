"""Extract the option tables of the kiro-cli top level, `chat` and `acp` from clap's `--help`.

Prints `{"cli": {"options": {<table>: {<long name>: <record>}}}}` on stdout and the
whole measured table on stderr, before any assertion on it. Reads either a binary
(`--binary`), which it runs with an empty HOME, auto-update off and no stdin, or a
directory of saved help output (`--help-dir`, files `top.txt`, `chat.txt`, `acp.txt`).

Only the option table is read: the description prose is not recorded, so a reworded
description never changes the output.
"""

import argparse
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

# Help table -> subcommand words. `acp` is a hidden subcommand and appears in no
# command listing, so the tables are declared here and not discovered.
TABLES = {"top": [], "chat": ["chat"], "acp": ["acp"]}

# `  -v, --verbose...`, `      --agent <AGENT>  prose`, `      --tui`. A count flag
# carries `...` after its name (or after its value name).
OPTION = re.compile(
    r"^  (?:(-[A-Za-z]), |    )(--[A-Za-z][A-Za-z0-9-]*)(\.\.\.)?"
    r"(?: <([^>]+)>(\.\.\.)?)?(?:\s{2,}(.*))?$"
)
SECTION_END = r"^[A-Z][A-Za-z ]+:\n"
# Option prose is indented further than the option lines themselves.
PROSE_INDENT = 8


def run_help(binary, words):
    with tempfile.TemporaryDirectory(prefix="kiro-cli-help.") as home:
        environment = {k: v for k, v in os.environ.items() if k not in ("COLUMNS", "LINES")}
        environment.update({"HOME": home, "KIRO_NO_AUTO_UPDATE": "1"})
        command = [binary, *words, "--help"]
        try:
            completed = subprocess.run(
                command, check=True, env=environment, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=30,
            )
        except subprocess.TimeoutExpired as error:
            raise SystemExit(f"cli-help: timed out after 30 seconds: {command!r}") from error
        except subprocess.CalledProcessError as error:
            raise SystemExit(f"cli-help: failed ({error.returncode}): {command!r}\n{error.stderr}") from error
    return completed.stdout


def parse_options(table, text):
    section = re.search(rf"(?ms)^Options:\n(.*?)(?={SECTION_END}|\Z)", text)
    if not section:
        raise SystemExit(f"cli-help: {table}: no Options section in the help output")
    records, bodies = [], []
    for line in section.group(1).splitlines():
        match = OPTION.match(line)
        if match:
            short, long, count_name, value_name, count_value, prose = match.groups()
            records.append({
                "aliases": [],
                "count": bool(count_name or count_value),
                "long": long,
                "possibleValues": [],
                "short": short,
                "takesValue": value_name is not None,
                "valueName": value_name,
            })
            bodies.append([prose] if prose else [])
        elif line.strip() and len(line) - len(line.lstrip()) < PROSE_INDENT:
            raise SystemExit(f"cli-help: {table}: option line not understood: {line!r}")
        elif line.strip():
            if not records:
                raise SystemExit(f"cli-help: {table}: prose before the first option: {line!r}")
            bodies[-1].append(line)
    for record, body in zip(records, bodies):
        prose = " ".join(part.strip() for part in body)
        aliases = re.search(r"\[aliases: ([^\]]+)\]", prose)
        inline = re.search(r"\[possible values: ([^\]]+)\]", prose)
        names = [m.group(1) for line in body if (m := re.match(r"^\s+- ([^\s:]+):", line))]
        if aliases:
            record["aliases"] = [item.strip() for item in aliases.group(1).split(",")]
        if inline:
            record["possibleValues"] = [item.strip() for item in inline.group(1).split(",")]
        elif any(line.strip() == "Possible values:" for line in body):
            record["possibleValues"] = names
    longs = [record["long"] for record in records]
    if len(set(longs)) != len(longs):
        raise SystemExit(f"cli-help: {table}: an option is listed twice: {longs!r}")
    return {record["long"]: record for record in records}


def print_table(tables):
    columns = ("table", "long", "short", "aliases", "value", "possible values", "count")
    rows = [
        (table, long, record["short"] or "-", ",".join(record["aliases"]) or "-",
         record["valueName"] or "-", ",".join(record["possibleValues"]) or "-",
         "yes" if record["count"] else "-")
        for table, options in tables.items() for long, record in options.items()
    ]
    widths = [max(len(row[index]) for row in [columns, *rows]) for index in range(len(columns))]
    print("cli-help: measured option table", file=sys.stderr)
    for row in [columns, *rows]:
        print("  " + "  ".join(cell.ljust(width) for cell, width in zip(row, widths)).rstrip(), file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--binary")
    source.add_argument("--help-dir")
    args = parser.parse_args()
    tables = {}
    for table, words in TABLES.items():
        text = run_help(args.binary, words) if args.binary else pathlib.Path(args.help_dir, f"{table}.txt").read_text()
        tables[table] = parse_options(table, text)
    print_table(tables)
    for table, options in tables.items():
        if not options:
            raise SystemExit(f"cli-help: {table}: the option table is empty")
    if "v3" not in tables["acp"].get("--agent-engine", {}).get("possibleValues", []):
        raise SystemExit("cli-help: acp --agent-engine no longer lists v3 among its possible values")
    json.dump({"cli": {"options": tables}}, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
