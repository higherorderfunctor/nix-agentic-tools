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

FENCE_MARK = re.compile(r"^(`{3,}|~{3,})")
LEADING_WS = re.compile(r"^[ \t]*")
# A list marker must be followed by whitespace or end the line; `---` is a
# thematic break, not a bullet with two more dashes after it.
LIST_MARKER = re.compile(r"^[ \t]*([-*+]|[0-9]{1,9}[.)])(?:([ \t]+)|$)")
# A GFM task-list checkbox. Strict CommonMark has no such construct and puts
# the item's content at `[`, but prettier — the formatter that actually
# produces this repo's wrapping — indents a task item's continuation lines
# past the checkbox. See `_list_content_column` for why using the spec column
# here fails OPEN.
TASK_MARKER = re.compile(r"\[[ xX]\][ \t]+")


def _column(prefix):
    """Column reached after PREFIX, with tab stops of 4 (the CommonMark rule)."""
    column = 0
    for char in prefix:
        column += 4 - (column % 4) if char == "\t" else 1
    return column


def _list_content_column(line):
    """Content column of the list item LINE opens, or None if it opens none.

    CommonMark puts an item's content at the column after its marker plus
    the following whitespace — except that 5+ spaces means the content is
    itself an indented code block, in which case the content column is the
    marker plus one. An empty item (`-` alone) is the same one-space case.

    A GFM TASK-LIST CHECKBOX COUNTS AS PART OF THE MARKER, which is a
    DELIBERATE DEPARTURE FROM THE SPEC and the only one here. Strict
    CommonMark knows no checkbox: `- [ ] text` is a bullet whose content
    starts at column 2 and whose `[ ]` is ordinary paragraph text. But the
    column that matters is the one PRETTIER produces, and prettier indents a
    task item's continuation lines past the checkbox, to column 6:

        - [ ] **Step 1:** a description long enough to wrap onto
              a second line

    Reading the spec column (2) there makes the continuation 6 - 2 = 4
    columns past content, so it is blanked as indented code — prose deleted
    from the scan, which FAILS OPEN. Reading 6 keeps it. The two errors are
    not symmetric: too high a content column merely scans a little code as
    prose (a visible false positive), too low deletes prose silently.

    CommonMark itself never makes that continuation code either, by a
    different rule — an indented chunk cannot interrupt an open paragraph —
    which this stripper does not model. Confirmed against pandoc: neither
    `-f commonmark` nor `-f gfm` yields a CodeBlock for the shape above.
    """
    match = LIST_MARKER.match(line)
    if not match:
        return None
    marker_end = _column(line[: match.end(1)])
    spaces = match.group(2)
    if not spaces:
        return marker_end + 1
    width = _column(line[: match.end(2)]) - marker_end
    if width > 4:
        return marker_end + 1
    checkbox = TASK_MARKER.match(line, match.end(2))
    if checkbox:
        return _column(line[: checkbox.end()])
    return marker_end + width


def strip_code_blocks(lines):
    """Blank out fenced and indented code blocks, preserving line numbering.

    A newline inside a fenced block is content, not a defect, so those
    regions must not be scanned. Lines are replaced rather than removed so
    reported line numbers still match the file.

    BOTH KINDS OF BLOCK ARE MEASURED RELATIVE TO THE ENCLOSING LIST ITEM,
    not to column zero, and getting that wrong fails OPEN — it deletes prose
    from the scan, so a defect inside the deleted text is reported as a
    clean file rather than as a skipped one.

    The flat `^ {4,}` rule this replaces blanked 1467 non-fenced, non-blank
    lines across 61 of the 220 scanned files. 1405 of them, in 51 files,
    are no longer blanked — 1361 ORDINARY PROSE plus 44 YAML frontmatter
    by the same oracle, and 0 code. `proseWrap = "always"` wraps a nested
    bullet's continuation lines to exactly four columns — and a task
    item's to six — and CommonMark's indented-code rule does not apply
    inside a list item, so that text is prose by the same spec the rest of
    the scan follows.

    The 62 lines still blanked, in 14 files, were CLASSIFIED RATHER THAN
    ASSUMED: each file was parsed with `pandoc -f commonmark+sourcepos -t
    json` and every CodeBlock's source range compared against them. 34 fall
    inside a code block, 16 of those being the body of a fence opened at
    column 4 that the flat rule blanked only by accident. The other 28 are
    YAML frontmatter, which this stripper does not model and which is not
    rendered prose either way. ZERO are prose.

    THAT LAST FIGURE IS THE ONE TO RE-DERIVE, NEVER TO TRUST. An earlier
    revision of this docstring asserted the residual was "genuine indented
    code" on no evidence at all. Running the oracle against it showed 210 of
    the 272 lines it then described — the same set `TASK_MARKER` has since
    cut to 62 — were prose, every one a GFM task-list continuation. The
    claim was wrong in the fail-open direction, and no corpus count could
    have shown it:
    the residual shrinks either by fixing the rule or by deleting more
    prose, and both look like progress. Re-run the oracle before editing
    any number here, and see checks/doubled-words-fixtures.nix for the
    fixtures that pin the shapes a corpus count cannot.

    The same offset governs FENCES, and skipping that half would be worse
    than the bug it fixes: a fence opened inside a nested item starts at
    column 4, `^ {0,3}` never sees it, and the whole fenced body would
    become "prose" the moment indented code stopped catching it by
    accident. So a stack of open list items' content columns is carried and
    both rules are applied at `column - content_column_of_innermost_item`.

    NOT MODELLED, none of which can move an item's content column — the one
    quantity this needs to be right about: blockquote containers (a
    `>`-prefixed fence opener matches nothing here, and doubled_words
    strips `>` only AFTER this has run, so quoted code reaches it as
    prose), setext headings, link reference definitions, and YAML
    frontmatter (an indented mapping inside it is blanked as if it were
    code — harmless, since frontmatter is not rendered prose, and it is
    where 28 of the 62 residual lines above come from).
    """
    out, i, n = [], 0, len(lines)
    stack = []  # content columns of the open list items, outermost first
    blank_before = True  # a list item stays open across the blank lines in it
    while i < n:
        line = lines[i]
        if not line.strip():
            out.append(line)
            blank_before = True
            i += 1
            continue
        whitespace = LEADING_WS.match(line).group(0)
        indent = _column(whitespace)
        content = _list_content_column(line)
        # Leave the items this line is still inside. A line dedented out of
        # an item closes it, EXCEPT as a lazy paragraph continuation — which
        # a new list marker never is, so a marker always pops.
        while stack and indent < stack[-1] and (blank_before or content is not None):
            stack.pop()
        base = stack[-1] if stack else 0
        opener = FENCE_MARK.match(line[len(whitespace) :])
        if indent - base <= 3 and opener:
            marker = opener.group(1)
            char, length = marker[0], len(marker)
            # A fence closes on a run of the SAME character, at least as
            # long as the opener, alone on its line. Its own indent is
            # bounded relative to the same content column the opener was.
            closer = re.compile(r"^[ \t]*" + re.escape(char) + "{" + str(length) + r",}\s*$")
            out.append("")
            i += 1
            while i < n:
                done = closer.match(lines[i]) and _column(LEADING_WS.match(lines[i]).group(0)) - base <= 3
                out.append("")
                i += 1
                if done:
                    break
            blank_before = False
            continue
        if indent - base >= 4:
            # An indented code block runs until a non-blank line dedents
            # back inside the item's content column. Blank lines inside it
            # stay blank either way, so they need no special case.
            out.append("")
            blank_before = False
            i += 1
            continue
        if content is not None:
            stack.append(content)
        out.append(line)
        blank_before = False
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


def no_files(name):
    """Fail a scan that received no files. Shared by every scanner here.

    A prose scanner asked to scan nothing prints "no findings in 0 files"
    and exits 0, and that is indistinguishable from a clean run of the real
    corpus. checks/markdown-scan.nix already refuses to invoke a scanner
    with an empty file list — but that guard protects the CALLER, not the
    scanner, and the second caller (a prek mirror is the obvious one) would
    reintroduce the hole. Keeping it here as well makes the invariant
    travel with the scanner. Belt and braces on purpose.
    """
    print(f"ERROR: {name} was invoked with no files to scan.", file=sys.stderr)
    print("A scan of nothing is not a pass. Whoever calls this scanner is", file=sys.stderr)
    print("responsible for the file list; see checks/markdown-scan.nix for", file=sys.stderr)
    print("the one that exists, and why `xargs -r` was not enough.", file=sys.stderr)
    return 1


def main(paths):
    if not paths:
        return no_files("split-code-spans")

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
