#!/usr/bin/env python3
"""Find a word repeated back to back in markdown PROSE ("the the").

Nothing else in the toolchain can see this class. prettier reflows the
paragraph and reproduces the duplicate verbatim; cspell checks words in
isolation and both spellings are real words; checks/split-code-spans.py
looks at backtick pairing, not at word sequences. `is the the rootfs top
level` shipped in #878 and reached main through review untouched by all
three, which is what this scanner exists to close.

── The hard part: an 80-column reflow splits the pair ────────────────

`treefmt`'s prettier runs `proseWrap = "always"` (see treefmt.nix), so
authored line breaks are discarded and prose is re-wrapped to 80 columns.
A duplicated word therefore lands across a newline roughly as often as it
lands on one line:

    … to measure what the launcher forwards, put the
    the wrapper first on PATH …

A line-oriented regex misses exactly that half of the defect class, and it
is not the half you can wave off — the reflow decides which half a given
instance falls into, so the split form is not rare, it is a coin flip.

The fix is smaller than reconstructing paragraphs, because a doubled word
is EXACTLY TWO TOKENS. The only cross-line shape it can take is (last
token of line N, first token of line N+1). So the scan is:

  1. every same-line pair, per line;
  2. the one boundary pair per adjacent line, when the two lines are
     joinable.

"Joinable" excludes a blank line (paragraph break) and any line that opens
a new block — heading, list marker, table row, thematic break, HTML — since
a word ending one block and a word opening the next are not adjacent prose.
Blockquote markers are the exception: `> ` is stripped rather than treated
as a break, because prettier prefixes EVERY wrapped line of a quoted
paragraph with it, and this repo's fragments carry their whole
`Last verified:` history inside blockquotes. Treating `>` as a boundary
would have blinded the scan to the corpus's longest prose blocks.

The boundary pair additionally requires the first word to be the last
thing on its line and the second to be the first thing on its. That is
what keeps a sentence break out: `… on that day.` / `Day one was …`
carries a period between the two words, so it is not a pair at all.

── Precision: measured, not assumed ─────────────────────────────────

THIS SECTION IS THE ONLY HOME OF THESE NUMBERS. checks/doubled-words.nix
and the markdown-formatting fragment both point here rather than restating
them, so there is one thing to update when a measurement moves.

A first cut over the 220 scanned files produced 23 hits, of which 1 was
real. All 22 false positives came from TOKENIZATION, not from word
choice — and both causes are fixed here rather than papered over with a
word list:

  1. MASKING A CODE SPAN WITH SPACES GLUES ITS NEIGHBOURS TOGETHER.
     `` on `chat` and `acp` and **not** at top level `` collapses to
     "on   and   and  not" once the spans become blanks, and "and and"
     is then a same-line hit that is not in the source at all. 16 of
     the 22 were this. Masked regions are therefore filled with a
     non-word, NON-SPACE placeholder (MASK below): neighbours stay
     separated, offsets and line numbers stay exact.
  2. A DOTTED IDENTIFIER IS NOT A WORD. `lower typed→settings.json JSON`
     read as "json JSON", and `config config.json` would read as
     "config config". A bare `\\b` boundary cannot tell the tail of an
     identifier from a word. The boundaries below therefore also refuse
     `-`, `_`, `/`, `'` and a `<alnum>.` prefix.

     The hyphen half of that rule is what kills the two known
     English-looking false positives on its own: `a per-turn opt-in in
     both versions` (the first `in` is the tail of `opt-in`) and
     `in in-memory` (the second `in` is the head of `in-memory`).

     `.` is refused on the LEFT of the first word and on the right only
     when an alphanumeric follows it. Refusing a trailing `.` outright
     would drop a genuine `… the the.` at the end of a sentence.

After both fixes the same corpus yields 1 hit: the #878 typo, reached
through `.github/instructions/kiro-wrapper.instructions.md`. Its source
fragment (packages/kiro-cli/docs/fhs-sandbox.md) is fixed in the same
commit as this scanner, and the projection is stale only until the
generator next runs — which is exactly the propagation the remedy text in
`main` is about. The other two projections of it are gitignored and never
enter the scanned set.

That figure has survived every later widening step — the list-aware prose
extraction (0 new hits), the emphasis/NBSP separators (0 new hits) and the
GFM task-list checkbox (0 new hits), all below. So the number to compare a
future measurement against is 1 while that projection is stale and 0 once
it is regenerated; nothing else in the corpus hits.

A CORPUS COUNT IS NOT A REGRESSION TEST, and treating it as one is how
the checkbox bug shipped. It cannot fail on a shape the corpus does not
contain, and when it does move it does not say which rule moved it —
worse, the count falls just the same whether the rule improved or the
scan quietly deleted more prose. checks/fixtures/doubled-words/ carries
the shapes instead: one small file per construct, each declaring in a
header what it proves and the exact hits it expects, run by
checks/doubled-words-fixtures.nix. Add a fixture with every rule change.

── Emphasis and NBSP separate a pair the reader still sees ──────────

`the *the*`, `the **the**`, `the\\n_the_` and `the<U+00A0>the` all render
as a doubled word, so all four are reported. They are handled by skipping
a bounded run of `*`, `_` and `~` around each word and by admitting
U+00A0 into the separator class — NOT by relaxing the boundary rules,
which is the version that looks equivalent and is not (see `_EMPHASIS`
below for the `snake_case case` regression that relaxing them reopens).

Measured before adopting it, which is the only reason it is here rather
than in an exclusions list: across the same 220 files the widened rule
produces ZERO additional hits, and the corpus contains ZERO U+00A0
characters. So the false-positive cost on real prose is nil and the
recall gain is entirely prospective. Ten positive controls (plain, `*`,
`**`, `_`, `~~`, an emphasis-wrapped pair, NBSP, two cross-line forms and
one inside an indented list continuation) and twelve negative controls
(`snake_case case`, `case case_sensitive`, `settings.json JSON`,
`opt-in in`, `in in-memory`, a code-span gap, fenced and indented code,
code indented inside a list item, a sentence break, a bullet boundary and
ordinary adjacent emphasis) pin both directions.

What is still NOT separated-but-visible: a doubling split by an inline
HTML tag (`the <b>the</b>`), by a footnote reference, or by a link
(`the [the](x)`). The corpus contains none, and each needs a different
rule; they are excluded, not overlooked.

── Why there is no stopword list ────────────────────────────────────

The obvious knob is to only flag function words (`the`, `a`, `in`, `of`).
It was not taken. Every measured false positive was a tokenization bug
that a stopword list would have hidden rather than fixed — `and and` and
`in in` are function words and would have survived the filter, while
`json JSON` would have been masked by it without the underlying rule
being any more correct. A word list is also a second maintenance surface
with silent, unmeasurable recall loss: nothing tells you about the
duplicate it declined to report.

So the scan is unrestricted, and the escape hatch is per-instance and
visible in the source instead. English does have legitimate doublings
("had had", "that that"); none occur in this corpus today. Suppress one
with a file-scoped marker:

    <!-- doubled-words: allow had had -->

Put it on its own line — prettier keeps a standalone HTML comment as its
own block, whereas one spliced into a paragraph gets reflowed and drifts
away from what it was pointing at. The marker is file-scoped for the same
reason.

A marker that suppresses nothing is itself an error. A suppression left
behind after the prose was fixed is a hole in the gate that no one can
see, which is the same failure mode as an empty scan reporting success.

── Scope: prose only, and what "prose" excludes ─────────────────────

Fenced and indented code blocks are blanked out by
`strip_code_blocks`, and inline code spans by the CommonMark backtick
rule in `code_spans` — both imported from split_code_spans rather than
reimplemented, so the pairing rule has one home. (See that module for why
the obvious `` `([^`]+)` `` regex is wrong; it is not a style preference,
it mis-pairs every span after the first multi-backtick one.) Repetition
inside code is routinely correct — this repo's own docs carry
`--bind /usr/local /usr/local` — and scanning it would have been the
third tokenization bug rather than a finding.

HTML comments are blanked for the same reason: they are not rendered
prose, and the allow-markers live in them.

THE EXACT BOUNDARY MATTERS HERE MORE THAN ANYWHERE ELSE, because getting
it wrong FAILS OPEN: anything `strip_code_blocks` blanks is prose this
scanner cannot see, and a hole there presents as a CLEAN FILE rather than
as a skipped one. The rule is CommonMark's, measured relative to the
enclosing list item's content column rather than to column zero — a line
is code at 4+ columns past that content column (0 at top level), or
inside a fence opened within 3 columns of it. The full statement of that
rule, and the count of prose the flat `^ {4,}` version deleted, are in
`strip_code_blocks`'s own docstring in split_code_spans; they are not
restated here.

Two numbers ARE this scanner's own, and both were re-measured after the
GFM task-list checkbox fix that followed:

  - Recall. Planting a doubling into a real four-column continuation line
    (.github/instructions/kiro-cli.instructions.md:348) goes UNDETECTED
    under the flat rule and is reported under this one, while a control
    doubling in an ordinary paragraph is caught by both. Repeating that
    against the task-list shape — one plant per file into a real `- [ ]`
    continuation — was 0/8 before the checkbox fix and 8/8 after. 11
    tracked files carry that shape; the other 3 continuations are made
    entirely of code spans, so there is no prose word in them to double.
  - Precision. Restoring that prose to the scan produced 0 new hits across
    the 220 files, both times: the corpus still yields exactly the 1 hit
    the "Precision" section above records. Two rounds of recall gain, no
    precision cost.

DELIBERATELY UNREPORTED, and NOT a gap to file: a doubling whose first
copy is the tail of a hyphenated compound. `_GLUE` refuses the tail and
the head of a hyphenated identifier, so this is silently accepted —

    … the record is next-keyed
    keyed by the tail of that identifier …

— and that is the SAME CHARACTER IN THE SAME RULE that makes `a per-turn
opt-in in both versions` and `the flag is in in-memory mode` correct
non-hits. Those two are the measured false positives it was added for;
this is what it costs. It bites hardest on the cross-line half, where
`-`-ending line tails are common, and it looks exactly like a recall bug
if you meet it without this paragraph — which is why it is written down
rather than left to be rediscovered. Relaxing the rule to recover the
first shape reopens the other two, so the trade is made knowingly and in
this direction. All three shapes, plus a control doubling proving the
file was scanned at all, are pinned in
checks/fixtures/doubled-words/hyphen-glue.md.fixture.

One shape leans the OTHER way and is worth knowing before it bites: a
fenced block nested inside a BLOCKQUOTE is scanned AS PROSE. Stripping
runs before `>` removal, so a `>`-prefixed fence opener matches no fence
rule, and the quoted code lines then reach the scan with their markers
stripped. That is a false-positive risk, not a hole — and the corpus has
zero such blocks (`grep '^[ \\t]*>[ \\t]*```'`), so it is left unhandled
rather than fixed speculatively. If one ever appears and repeats a word,
suppress that file and fix the stripper.
"""

import re
import sys

from split_code_spans import code_spans, no_files, strip_code_blocks

# Blanked regions are filled with this rather than with spaces. A space
# would let the words on either side of a code span become adjacent and
# fabricate a pair — measured at 16 false positives out of 22. It is not
# whitespace and not a word character, so it terminates a token without
# joining anything. Newlines inside a masked region are preserved so
# reported line numbers still match the file.
MASK = "\x01"

ALLOW = re.compile(r"<!--\s*doubled-words:\s*allow\s+(.+?)\s*-->", re.S)
BACKTICKS = re.compile(r"`+")
HTML_COMMENT = re.compile(r"<!--.*?-->", re.S)
QUOTE = re.compile(r"^(?:[ \t]*>)+[ \t]?")

# A line matching this OPENS a block, so it cannot continue the line above.
BLOCK_OPEN = re.compile(
    r"""^[ \t]*(?: $
                 | \#{1,6}[ \t]
                 | [-*+][ \t]
                 | [0-9]+[.)][ \t]
                 | \|
                 | (?: -{3,} | \*{3,} | _{3,} | ={3,} )[ \t]*$
                 | <
                 )""",
    re.X,
)
# A line matching this is ATOMIC: the line below cannot continue it. Bullets
# and ordered items are absent on purpose — their own wrapped continuation
# lines are prose and must stay joinable.
BLOCK_ATOM = re.compile(
    r"""^[ \t]*(?: \#{1,6}[ \t]
                 | \|
                 | (?: -{3,} | \*{3,} | _{3,} | ={3,} )[ \t]*$
                 | <
                 )""",
    re.X,
)

# Token boundaries. `\b` is not enough: it treats the tail of a dotted or
# hyphenated identifier as a standalone word. See the docstring's
# "Precision" section for the four measured shapes these two refuse.
_GLUE = r"0-9A-Za-z_'’/-"
LEFT = rf"(?<![{_GLUE}])(?<![0-9A-Za-z]\.)"
RIGHT = rf"(?![{_GLUE}])(?!\.[0-9A-Za-z])"

# Emphasis renders away, so `the *the*` reaches the reader as a doubling.
# A bounded run of markers is therefore skipped on either side of both
# words — but ONLY INSIDE the boundary assertions, never by dropping `_`
# from `_GLUE`. Dropping it there is the tempting one-character version and
# it silently reopens the dotted-identifier FP class: `snake_case case`
# would start matching at `case`, because the `_` before it would no longer
# be glue. Asserting the boundary first and consuming the run afterwards
# keeps `snake_case case` and `case case_sensitive` refused while `_the
# the_` and `the **the**` are caught.
_EMPHASIS = r"[*_~]{0,3}"
# U+00A0 is a word separator that renders as a space. It is in the gap
# class for the same reason emphasis is skipped: the reader sees a doubling.
_GAP = "[ \t\u00a0]+"

SAME_LINE = re.compile(
    LEFT + _EMPHASIS + r"([A-Za-z]+)" + _EMPHASIS + _GAP + _EMPHASIS + r"(\1)" + _EMPHASIS + RIGHT,
    re.I,
)
# The first word must be the last thing on its line, and the second the
# first thing on the next — anything between them (a period, a bracket, a
# masked code span) means they are not an adjacent pair.
TAIL = re.compile(LEFT + _EMPHASIS + r"([A-Za-z]+)" + _EMPHASIS + r"[ \t]*$")
HEAD = re.compile(r"^[ \t]*" + _EMPHASIS + r"([A-Za-z]+)" + _EMPHASIS + RIGHT)

PROJECTIONS = (".claude/rules/", ".github/instructions/", ".kiro/steering/")


def is_projection(path):
    """Is this path a GENERATED instruction file rather than a source?

    The `./` strip is load-bearing: the check feeds paths straight from
    `find .`, so every one of them is `./`-prefixed and a bare
    `startswith(PROJECTIONS)` is false for all of them. Measured — the
    remedy paragraph below silently never printed, on the one hit the
    corpus actually has.
    """
    return path.removeprefix("./").startswith(PROJECTIONS)


def normalize(bigram):
    """Collapse a bigram to its comparable form: lowercase, single-spaced."""
    return " ".join(bigram.strip("\"'").split()).lower()


def code_span_regions(text):
    """Yield (start, end) for every inline code span."""
    for start, content in code_spans(text):
        # code_spans yields the span's OPENING offset and its content, not
        # its extent. The opening backtick run is re-measured here rather
        # than widening that generator's contract, which split_code_spans
        # unpacks as a 2-tuple. CommonMark closes a span on a run of the
        # same length, so the extent is content + both runs.
        run = len(BACKTICKS.match(text, start).group(0))
        yield start, start + 2 * run + len(content)


def html_comment_regions(text):
    """Yield (start, end) for every HTML comment."""
    for match in HTML_COMMENT.finditer(text):
        yield match.start(), match.end()


def mask(text, regions):
    chars = list(text)
    for start, end in regions:
        for index in range(start, end):
            if chars[index] != "\n":
                chars[index] = MASK
    return "".join(chars)


def prose(text):
    """Reduce a document to (allowed bigrams, prose lines).

    Line numbering is preserved throughout: everything discarded is
    overwritten in place rather than removed.
    """
    text = "\n".join(strip_code_blocks(text.split("\n")))
    text = mask(text, code_span_regions(text))
    # Allow markers are read after code blocks and code spans are gone, so
    # that a marker SHOWN AS AN EXAMPLE in documentation is documentation
    # and not a directive. The markdown-formatting fragment demonstrates
    # the syntax in a fenced block; without this ordering that example
    # would register as a live suppression, find nothing to suppress, and
    # fail the check on the file that explains the feature.
    allowed = {normalize(m.group(1)) for m in ALLOW.finditer(text)}
    text = mask(text, html_comment_regions(text))
    # Blockquote markers become SPACES, not MASK: they sit at line start
    # where they cannot glue two words together, and a MASK there would
    # stop HEAD from ever matching a quoted continuation line.
    lines = [QUOTE.sub(lambda m: " " * len(m.group(0)), line) for line in text.split("\n")]
    return allowed, lines


def doubled(lines):
    """Yield (line_number, first_word, second_word) for each doubled word."""
    for index, line in enumerate(lines):
        for match in SAME_LINE.finditer(line):
            yield index + 1, match.group(1), match.group(2)
        if index + 1 == len(lines):
            continue
        following = lines[index + 1]
        if not line.strip() or BLOCK_ATOM.match(line) or BLOCK_OPEN.match(following):
            continue
        tail, head = TAIL.search(line), HEAD.match(following)
        if tail and head and tail.group(1).lower() == head.group(1).lower():
            yield index + 1, tail.group(1), head.group(1)


def scan(path):
    """Return (hits, unused_allow_markers) for one file."""
    with open(path, encoding="utf-8") as handle:
        allowed, lines = prose(handle.read())
    hits, used = [], set()
    for line, first, second in doubled(lines):
        bigram = f"{first} {second}"
        if normalize(bigram) in allowed:
            used.add(normalize(bigram))
            continue
        hits.append((line, bigram))
    return hits, sorted(allowed - used)


def main(paths):
    if not paths:
        return no_files("doubled-words")

    hits, stale = [], []
    for path in paths:
        file_hits, file_stale = scan(path)
        hits += [(path, line, bigram) for line, bigram in file_hits]
        stale += [(path, marker) for marker in file_stale]

    if not hits and not stale:
        print(f"No doubled words found in {len(paths)} markdown files.")
        return 0

    if hits:
        print("ERROR: a word is repeated back to back in markdown prose.")
        print()
        for path, line, bigram in hits:
            print(f'  {path}:{line}: "{bigram}"')
        print()
        print("Delete the duplicate. Note the pair may be SPLIT ACROSS THE")
        print("NEWLINE at the end of the reported line — prettier reflows")
        print("prose to 80 columns, so check the following line too.")
        print()
        if any(is_projection(path) for path, _, _ in hits):
            print("Some hits are in GENERATED projections (.claude/rules/,")
            print(".github/instructions/, .kiro/steering/). Fix the source")
            print("fragment under dev/fragments/ or packages/*/docs/ and run")
            print("`devenv tasks run --mode before generate:all`. Never edit")
            print("a projection directly.")
            print()
        print("If a doubling is deliberate English (\"had had\"), suppress it")
        print("with a marker on its own line anywhere in the same file:")
        print()
        print("  <!-- doubled-words: allow had had -->")
        print()

    if stale:
        print("ERROR: doubled-words allow marker(s) suppressing nothing.")
        print("The prose was fixed but the suppression stayed, leaving a")
        print("hole in this check that nothing else would report. Remove:")
        print()
        for path, marker in stale:
            print(f'  {path}: "{marker}"')
        print()

    if hits:
        print(f"{len(hits)} doubled word(s) in {len({h[0] for h in hits})} file(s).")
    return 1


if __name__ == "__main__":
    sys.exit(main(sorted(sys.argv[1:])))
