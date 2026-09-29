#!/usr/bin/env python3
"""Flag steering directives an agent cannot grade itself against.

A rule is a defect when two competent agents, reading it with the same diff in
front of them, could reach OPPOSITE conclusions about whether it applies or
whether they have satisfied it. That happened eleven times across this corpus
before anyone looked, and the most expensive one gated a multi-agent review
protocol on the undefined word "complex".

The test here is deliberately cheap and deliberately incomplete: a line that
COMMANDS something, containing a magnitude or frequency word, in a paragraph
carrying no anchor a reader could check the rule against. Anchors are the
things this repo's good rules actually key on -- a path or glob, a check name,
a command, or a number with a unit.

NOT a gate. It reports; it does not block. A false positive here would be
friction on every documentation edit forever, so it earns promotion by being
quiet first. Run it with `devenv tasks run lint:gradeability`.

Escape hatch: put `<!-- gradeable: operator-judgement -->` in the paragraph.
That turns "the operator meant this to be a human call" from an invisible
property into a grep-able one, which is the thing the audit that motivated this
had to reconstruct by hand for every candidate.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# Words that route a decision without saying how to evaluate it. Each one below
# was found gating real behavior in this corpus, or is the same shape.
VAGUE = re.compile(
    r"\b(complex|significant(?:ly)?|substantial(?:ly)?|large(?:ly)?|minor|"
    r"thorough(?:ly)?|meaningful(?:ly)?|serious(?:ly)?|pedantic|"
    r"regularly|periodically|promptly|appropriate(?:ly)?|as needed|"
    r"when appropriate|reasonable|reasonably|sufficient(?:ly)?|vague)\b",
    re.I,
)

# A line that tells the reader to do something. Bolded bullet openers count:
# this corpus states most of its rules as `- **Do the thing.** ...`.
IMPERATIVE = re.compile(
    # Strong modals anywhere on the line...
    r"\bMUST\b|\bNEVER\b|\bALWAYS\b|\bdo not\b|\bnever\b|\balways\b"
    # ...a bolded bullet opener, which is how most rules here are written --
    # but NOT a purely numeric one, which is how rubric anchors are written
    # ("**50**: moderately confident").
    r"|^\s*(?:[-*]|\d+\.)\s+\*\*(?!\d+\*\*)"
    # ...or a directive verb in the IMPERATIVE POSITION. Matching these verbs
    # anywhere on the line was the first version and it was far too loose: a
    # rubric sentence describing a confidence band tripped on the word "check"
    # eight words later.
    r"|^\s*(?:[-*]\s+)?(?:Flag|Add|Run|Escalate|Drop|Prefer|Keep|Stop|Verify|"
    r"Check|Write|Use|Treat|Require|Report|Surface|Split|Move|Delete)\b",
    re.I | re.M,
)
# Something a reader can actually check the rule against.
ANCHOR = re.compile(
    r"`[^`]*[/*][^`]*`"          # a path, a glob, or a command with a slash
    r"|`checks/[^`]+`"           # a named check
    r"|\bchecks/\S+\.nix\b"
    r"|`[a-z][\w.-]*\s[^`]+`"    # a backticked command with an argument
    r"|\b\d[\d,]*\s*(bytes?|KB|MB|lines?|rounds?|files?|seconds?|minutes?|%|"
    r"entries|agents?|commits?)\b"
)

ESCAPE = "<!-- gradeable: operator-judgement -->"

# Cross-references that break silently on every edit and that nothing lints.
DEAD_REF = re.compile(r"\brule\s+\d+\b|\bthe (first|second|third|fourth) bullet\b", re.I)

ROOTS = ("dev/fragments", "dev/skills", "packages")


def paragraphs(text: str):
    """Yield (start_line, [lines]) with fenced code blocks removed."""
    out, buf, start, fence = [], [], 1, False
    for n, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("```"):
            fence = not fence
            continue
        if fence:
            continue
        if line.strip():
            if not buf:
                start = n
            buf.append((n, line))
        elif buf:
            out.append((start, buf))
            buf = []
    if buf:
        out.append((start, buf))
    return out


def scan(path: Path):
    findings = []
    text = path.read_text(encoding="utf-8")
    for _start, block in paragraphs(text):
        body = "\n".join(l for _, l in block)
        if ESCAPE in body:
            continue
        anchored = ANCHOR.search(body) is not None
        for n, line in block:
            if DEAD_REF.search(line):
                findings.append((n, line.strip(), "cites an ordinal that breaks on any edit"))
                continue
            if anchored:
                continue
            m = VAGUE.search(line)
            if m and IMPERATIVE.search(line):
                findings.append(
                    (n, line.strip(), f"'{m.group(0)}' gates an action, and nothing in the paragraph anchors it")
                )
    return findings


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    # `is_file()` also rejects dangling symlinks, which this tree has: the
    # skills' reference/ dirs point into the store and are only materialized on
    # shell entry.
    files = sorted(
        p
        for r in ROOTS
        for p in (root / r).rglob("*.md")
        if p.is_file() and (str(p.relative_to(root)).startswith("dev/") or "/docs/" in str(p))
    )
    total = 0
    for path in files:
        for line_no, line, why in scan(path):
            total += 1
            rel = path.relative_to(root)
            print(f"{rel}:{line_no}: {why}")
            print(f"    {line[:140]}")
    print()
    print(f"gradeability: {total} finding(s) across {len(files)} file(s) - reporting only, not a gate")
    return 0


if __name__ == "__main__":
    sys.exit(main())
