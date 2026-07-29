#!/usr/bin/env python3
"""Find inline code spans whose content is split across a newline.

CommonMark converts that newline to a SPACE, so the rendered output is
valid — this is not a rendering bug in the general case. It is caught for
two reasons:

  1. Raw-source legibility. These fragments are consumed by agents reading
     raw markdown out of `.claude/rules/`, `.github/instructions/`, and
     `.kiro/steering/` — never rendered HTML. A span broken mid-expression
     reads as two fragments.
  2. A minority DO render wrong. Where the break lands mid-token the
     inserted space goes inside an identifier or path. Measured with
     pandoc -f gfm:
         `programs.claude-code.\\nmarketplaces`
             -> <code>programs.claude-code. marketplaces</code>
         `home.file.".claude/\\nrules/${name}.md".text`
             -> <code>home.file.".claude/ rules/${name}.md".text</code>
     Copy-pasting either yields a broken Nix attribute path.

     TRAP, learned the hard way. This check does NOT catch case 2 once the
     reflow has run, and a render comparison will not tell you so. Prettier
     joins the span by printing its CommonMark VALUE — space included — so
     the newline disappears while the defect stays. That means a pandoc
     before/after showing "renders identically" is NOT a safety signal
     here: for a mid-token span it is proof the bug SURVIVED. PR #589
     shipped claiming a fix it had not made because that output was read
     as reassurance. The class is not lintable (a glue-char-plus-space
     heuristic measured 96 hits, ~90% of them legitimate: `env // omEnv`,
     `nix-update --flake`, `<!-- header -->`, `low / medium / high`,
     `pre- or post-`), so it is prevented at authoring time by the
     markdown-formatting fragment instead.

`treefmt`'s prettier runs with `proseWrap = "always"`, which treats a code
span as an unbreakable token and therefore CANNOT emit one of these. That
formatter is the primary guardrail; this check is the backstop for what it
cannot reach:

  - CASCADING backtick mis-nesting. Prettier repairs an ISOLATED one
    (verified: re-breaking a single `` !`command` `` into `` `!`command` ``
    and re-running treefmt restores the correct form). What defeats it is
    several in one file: once a span mis-pairs, every backtick downstream
    shifts, and prettier's own parse is wrong, so its output still holds
    real splits. Measured on the two files fixed alongside this check —
    pristine, after `treefmt`, 18 spans across 2 files survived. mdformat
    left 13 on the same input.
  - Files excluded from prettier in treefmt.nix.

There is deliberately no suppression marker. A split span is never the
intent; the fix is to repair the markdown, which is what the formatter
does automatically everywhere it can.

── Why not a one-line regex ──────────────────────────────────────────

The obvious scanner is `re.finditer(r'`([^`]+)`', text)`, and it is wrong.
CommonMark's rule is that a span opened by a run of N backticks closes at
the next run of EXACTLY N. The naive pattern pairs any backtick with the
next one, so a single multi-backtick span (`` !`command` ``, or an empty
`` `` ``) shifts the pairing by one for the REST OF THE FILE and every
subsequent "hit" is the text BETWEEN two real spans.

That is not theoretical. Measured on this repo when the check was written:
the naive scanner reported 33 hits in one docs/ file of which 0 were real,
while missing entire directories it never scanned. The correct rule found
369 real spans across 66 files where the naive one had claimed 32 across
15. Do not "simplify" this back into a regex.
"""

import re
import sys

FENCE_OPEN = re.compile(r"^ {0,3}(`{3,}|~{3,})")
INDENTED = re.compile(r"^( {4,}|\t)")


def strip_code_blocks(lines):
    """Blank out fenced and indented code blocks, preserving line numbering.

    A newline inside a fenced block is content, not a defect, so those
    regions must not be scanned. Lines are replaced rather than removed so
    reported line numbers still match the file.
    """
    out, i, n = [], 0, len(lines)
    while i < n:
        opener = FENCE_OPEN.match(lines[i])
        if opener:
            marker = opener.group(1)
            char, length = marker[0], len(marker)
            # A fence closes on a run of the SAME character, at least as
            # long as the opener, alone on its line.
            closer = re.compile(r"^ {0,3}" + re.escape(char) + "{" + str(length) + r",}\s*$")
            out.append("")
            i += 1
            while i < n:
                done = closer.match(lines[i])
                out.append("")
                i += 1
                if done:
                    break
            continue
        out.append("" if INDENTED.match(lines[i]) else lines[i])
        i += 1
    return out


def code_spans(text):
    """Yield (offset, content) for each inline code span, CommonMark rule."""
    runs = [(m.start(), len(m.group(0))) for m in re.finditer(r"`+", text)]
    i = 0
    while i < len(runs):
        start, length = runs[i]
        # Closing run must be exactly as long as the opening run.
        j = next((k for k in range(i + 1, len(runs)) if runs[k][1] == length), None)
        if j is None:
            i += 1
            continue
        yield start, text[start + length : runs[j][0]]
        i = j + 1


def scan(path):
    text = "\n".join(strip_code_blocks(open(path, encoding="utf-8").read().split("\n")))
    for offset, content in code_spans(text):
        if "\n" in content:
            yield text.count("\n", 0, offset) + 1, " ".join(content.split())


def main(paths):
    hits = [(p, line, body) for p in paths for line, body in scan(p)]
    if not hits:
        print(f"No split inline code spans found in {len(paths)} markdown files.")
        return 0
    print("ERROR: inline code spans split across a newline.")
    print("CommonMark turns the newline into a space, which is unreadable in")
    print("raw source and corrupts the span outright when the break lands")
    print("mid-token. Rewrite so the span sits on one line, or promote a")
    print("multi-line snippet to a fenced code block.")
    print()
    for path, line, body in hits:
        print(f"  {path}:{line}: `{body[:100]}`")
    print()
    print(f"{len(hits)} span(s) in {len({h[0] for h in hits})} file(s).")
    return 1


if __name__ == "__main__":
    sys.exit(main(sorted(sys.argv[1:])))
