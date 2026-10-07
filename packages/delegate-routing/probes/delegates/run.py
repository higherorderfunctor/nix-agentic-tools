#!/usr/bin/env python3
"""Re-run delegate-map cases straight from the harness READMEs' case tables.

    python3 run.py --list                      # every case id, its status, its command
    python3 run.py --only=kimchi/claude:s1-fg-pins
    python3 run.py --only='kimchi/claude:sp-*,codex/codex:R1.*'
    python3 run.py --only=claude:dmu_wf_effort # a bare case id matches every harness

Prints one MATCH, MISMATCH or SKIP line per case. The exit code is the
MISMATCH count (capped at 125). LIVE cases are skipped unless `--live`.

Case-table format (what this runner reads; register a new case by adding a row):

- A table counts when its header has a `Case id` (or `Id`) column and a column
  whose name starts with `Expected excerpt`. A `Command` column is optional;
  a `Kind` column holding `LIVE` (or `LIVE` in the command cell) marks a LIVE
  case. Rows split ids on ` / `; the qualified id is `<harness>/<case id>`.
- Command cell: backtick spans, run with bash (strict mode) from the harness
  directory. Spans separated only by spaces join into one command; `;`, `,` or
  `then` start the next command. Text in parentheses is a comment. A one-word
  span, or one starting with `…`, continues the previous command by replacing
  its last word (path segments for a path). A cell that does not start with a
  backtick is prose: the case is SKIP. So is a command holding a `<placeholder>`.
  A bare `x.py` first word runs under python3. Harness aliases are in ALIASES.
- Expected excerpt cell: every backtick span is a literal the command's
  stdout+stderr must contain, except file-name locators (`001.json`, `out/`).
  `…` (or `...`) inside a span matches anything on the same line. A span
  preceded by `no `/`not `/`without ` or followed by ` absent` must NOT appear.
  A cell with no backtick literal is SKIP (no excerpt), never a MATCH.
- Tables without a Command column take their section's default from
  SECTION_DEFAULTS ({id} = case id, {name} = the id after its last `:`).

Every run gets a scratch `PROBE_OUT` (default under /var/tmp); each case's
output is kept in `<out>/<case>.log`.
"""

import argparse
from dataclasses import dataclass, field
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "eval"))
from suite import select  # noqa: E402  (one --only matcher for both runners)

STRICT = "set -euETo pipefail\nshopt -s inherit_errexit 2>/dev/null || :\n"
MAX_EXIT = 125

# Shorthands the READMEs define in prose, per harness: (regex, replacement).
ALIASES = {
    "kimchi": [
        (r"^drive\s+(\S+)$", r'python3 live/drive.py live/sc/\1.json "$PROBE_OUT/kimchi/\1" && python3 live/summ.py "$PROBE_OUT/kimchi/\1"'),
        (r"^sp\s+(\S+)$", r'python3 live/prompt_map.py \1 && cat "$PROBE_OUT/kimchi-prompt-map/\1/prompt-map.txt"'),
    ],
    "kiro": [
        (r"(?<=\s)ACP3(?=\s|$)", "-- acp --agent-engine v3 --auth-method cli"),
        (r"(?<=\s)K(?=\s|$)", '"MAIN_KICKOFF USER_SENTINEL_1"'),
    ],
}
# Environment the READMEs define in prose, per harness.
ENV = {
    "claude": {"CLAUDE_PROBE_WORK": "{out}/claude"},
    "codex": {"H6": "CFG-DEV-4000 REQ-ADI-4001 HOOK-SESSSTART-4002 HOOK-UPS-4003 HOOK-SUBSTART-4004 HOOK-POSTTOOL-4005"},
}
# Commands for tables with no Command column: (harness, heading substring) -> template.
SECTION_DEFAULTS = {
    ("claude", "Delegate unknowns"): "python3 harness.py {name} && python3 dmu_show.py {name}",
    ("kiro", "Prompt-reach"): "./pr-replay.sh {id}",
}
LOCATOR = re.compile(r"^[\w.*/<>-]*(\.(json|jsonl|txt|log|md|py|cjs|js|ts|sh|toml|output)|/)$")
PLACEHOLDER = re.compile(r"<[A-Za-z][\w .-]*>")
ELLIPSIS = re.compile(r"…|\.\.\.")


@dataclass
class Case:
    harness: str
    id: str
    readme: str
    line: int
    commands: list = field(default_factory=list)
    needles: list = field(default_factory=list)  # (fragments, present)
    live: bool = False
    skip: str = ""

    @property
    def qid(self):
        return f"{self.harness}/{self.id}"


def cells(line):
    """GFM row cells: split on unescaped pipes, then unescape `\\|`."""
    return [cell.strip().replace("\\|", "|") for cell in re.split(r"(?<!\\)\|", line.strip().strip("|"))]


def spans(text):
    """(start, end, content) of each backtick span."""
    return [(m.start(), m.end(), m.group(1)) for m in re.finditer(r"`([^`]+)`", text)]


def drop_parentheses(text):
    """Remove (comments) outside backtick spans."""
    out, depth, code = [], 0, False
    for char in text:
        if char == "`" and depth == 0:
            code = not code
        if not code and char == "(":
            depth += 1
        if depth == 0:
            out.append(char)
        if not code and char == ")" and depth:
            depth -= 1
    return "".join(out)


def continue_from(previous, word):
    """`… x` or a bare `x` after `prev` replaces prev's last word (or path tail)."""
    word = ELLIPSIS.sub("", word).strip()
    head, _, last = previous.rpartition(" ")
    depth = word.count("/") + 1
    parts = last.split("/")
    last = "/".join(parts[:-depth] + [word]) if len(parts) > depth else word
    return f"{head} {last}".strip()


def parse_commands(cell):
    text = drop_parentheses(cell).strip()
    if not text.startswith("`"):
        return []
    commands, end = [], 0
    for start, stop, body in spans(text):
        gap = text[end:start]
        body = body.strip()
        if commands and not gap.strip():
            commands[-1] += " " + body
        elif commands and not re.fullmatch(r"\s*(;|,)?\s*(then)?\s*", gap):
            break  # prose after the commands
        elif commands and (ELLIPSIS.match(body) or " " not in body and "/" not in body and not body.endswith((".py", ".sh"))):
            commands.append(continue_from(commands[-1], body))
        else:
            commands.append(body)
        end = stop
    return commands


def parse_needles(cell):
    needles = []
    for start, stop, body in spans(cell):
        if LOCATOR.match(body.strip()):
            continue
        before, after = cell[:start], cell[stop:]
        absent = bool(re.search(r"\b(no|not|without)\s+$", before, re.I) or re.match(r"\s+absent\b", after))
        fragments = [part.strip() for part in ELLIPSIS.split(body) if part.strip()]
        if fragments:
            needles.append((fragments, not absent))
    return needles


def expand(harness, command):
    for pattern, replacement in ALIASES.get(harness, []):
        command = re.sub(pattern, replacement, command)
    if re.match(r"^[\w-]+\.py(\s|$)", command):
        command = "python3 " + command
    return command


def discover(root):
    cases, seen = [], {}
    for readme in sorted(root.glob("*/README.md")):
        harness = readme.parent.name
        header, heading = None, ""
        for number, line in enumerate(readme.read_text().splitlines(), 1):
            if line.startswith("#"):
                heading = line.lstrip("#").strip()
            if not line.startswith("|"):
                header = None
                continue
            row = cells(line)
            if header is None:
                header = row
                continue
            if all(set(cell) <= set("-: ") for cell in row):
                continue
            columns = dict(zip(header, row))
            ids = columns.get("Case id", columns.get("Id"))
            expected = next((value for key, value in columns.items() if key.startswith("Expected excerpt")), None)
            if ids is None or expected is None:
                continue
            command_cell = columns.get("Command")
            for case_id in [part.strip() for part in ids.split(" / ") if part.strip()]:
                case = Case(harness, case_id, str(readme.relative_to(root)), number)
                if command_cell is not None:
                    case.commands = parse_commands(command_cell)
                    case.live = bool(re.search(r"\bLIVE\b", re.sub(r"`[^`]*`", "", command_cell)))
                else:
                    template = next((value for (owner, part), value in SECTION_DEFAULTS.items() if owner == harness and part in heading), None)
                    case.commands = [template.format(id=case_id, name=case_id.rsplit(":", 1)[-1])] if template else []
                case.live = case.live or columns.get("Kind", "").strip() == "LIVE"
                case.commands = [expand(harness, command) for command in case.commands]
                case.needles = parse_needles(expected)
                if not case.commands:
                    case.skip = "no runnable command (prose cell or no section default)"
                elif any(PLACEHOLDER.search(command) for command in case.commands):
                    case.skip = "command needs input: " + ", ".join(sorted({m for c in case.commands for m in PLACEHOLDER.findall(c)}))
                elif not case.needles:
                    case.skip = "no backtick literal in the expected excerpt"
                seen[case.qid] = seen.get(case.qid, 0) + 1
                if seen[case.qid] > 1:
                    case.id += f"#{seen[case.qid]}"
                cases.append(case)
    return cases


def check(case, output):
    missing, unexpected = [], []
    for fragments, present in case.needles:
        pattern = re.compile(".*?".join(map(re.escape, fragments)))
        found = bool(pattern.search(output))
        label = " … ".join(fragments)
        if present and not found:
            missing.append(label)
        elif not present and found:
            unexpected.append(label)
    return missing, unexpected


def run(case, root, out, timeout):
    env = {**os.environ, "PROBE_OUT": str(out)}
    env.update({key: value.format(out=out) for key, value in ENV.get(case.harness, {}).items()})
    output, codes = [], []
    log = out / (re.sub(r"[^\w.-]+", "_", case.qid) + ".log")
    for command in case.commands:
        probe = re.search(r"(?:^|\s)\./run\.sh\s+(\S+)", command)
        if case.harness == "codex" and probe:
            env["R"] = f"{out}/codex/results/{probe.group(1)}"
        try:
            result = subprocess.run(["bash", "-c", STRICT + command], cwd=root / case.harness, env=env, stdin=subprocess.DEVNULL,
                                    capture_output=True, text=True, errors="replace", timeout=timeout)
            output.append(result.stdout + result.stderr)
            codes.append(result.returncode)
        except subprocess.TimeoutExpired as error:
            # text=True does not decode the partial output a timeout carries.
            output.append("".join(part.decode(errors="replace") if isinstance(part, bytes) else part or ""
                                  for part in (error.stdout, error.stderr)))
            codes.append(f"timeout {timeout}s")
    log.write_text("".join(f"$ {command}\n{text}\n" for command, text in zip(case.commands, output)))
    return "\n".join(output), codes, log


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--list", action="store_true", help="print case ids, status and command; run nothing")
    parser.add_argument("--only", action="append", default=[], metavar="ID[,ID|PREFIX*]",
                        help="run only these cases (qualified harness/id or bare id); a trailing * matches a prefix")
    parser.add_argument("--live", action="store_true", help="also run LIVE cases (operator login, real quota)")
    parser.add_argument("--out", type=Path, help="scratch PROBE_OUT and per-case logs; default a fresh /var/tmp dir")
    parser.add_argument("--root", type=Path, default=HERE, help=argparse.SUPPRESS)
    parser.add_argument("--timeout", type=int, default=1200, help="seconds per command (default 1200)")
    args = parser.parse_args(argv)
    cases = select(discover(args.root), args.only, lambda case: [case.qid, case.id])
    if args.list:
        for case in cases:
            status = case.skip or ("LIVE" if case.live else "runnable")
            print(f"{case.qid}\t{status}\t{' ; '.join(case.commands)}")
        return 0
    out = args.out or Path(tempfile.mkdtemp(prefix="delegate-probes-run-", dir="/var/tmp"))
    out.mkdir(parents=True, exist_ok=True)
    tally = {"MATCH": 0, "MISMATCH": 0, "SKIP": 0}
    for case in cases:
        reason = case.skip or ("LIVE (pass --live)" if case.live and not args.live else "")
        if reason:
            tally["SKIP"] += 1
            print(f"SKIP      {case.qid}  {reason}", flush=True)
            continue
        started = time.monotonic()
        text, codes, log = run(case, args.root, out, args.timeout)
        missing, unexpected = check(case, text)
        verdict = "MISMATCH" if missing or unexpected else "MATCH"
        tally[verdict] += 1
        detail = "".join([f"  missing {missing}" if missing else "", f"  unexpected {unexpected}" if unexpected else ""])
        print(f"{verdict:<9} {case.qid}  rc={codes} {time.monotonic() - started:.1f}s{detail}  log={log}", flush=True)
    print(f"\n{tally['MATCH']} match, {tally['MISMATCH']} mismatch, {tally['SKIP']} skip; out: {out}")
    return min(tally["MISMATCH"], MAX_EXIT)


if __name__ == "__main__":
    sys.exit(main())
