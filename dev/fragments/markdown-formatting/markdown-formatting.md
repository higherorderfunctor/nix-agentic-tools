### Markdown Formatting

`treefmt` owns markdown wrapping. Prettier runs with
`settings.proseWrap = "always"` (see `treefmt.nix`), so it reflows every
paragraph to 80 columns on format. **Do not hand-wrap prose** — the line breaks
you author are discarded, and hand-wrapping is what created the defect below.

### Never break a line mid-token

> **Last verified:** 2026-08-12 (commit pending — records
> `checks/doubled-words.*`, the third markdown gate, and narrows this section's
> claim: "no check can catch it" was always about a break landing MID-TOKEN, and
> a reader could fairly have read it as covering repetition across the same
> break, which is now caught. Also records that the file set both scans walk
> moved into the shared `checks/markdown-scan.nix`, and that `proseWrap`'s
> four-column continuation indent collides with CommonMark's indented-code rule
> — the shared prose extraction is list-aware for that reason, having been
> measured deleting most of a corpus of real prose before it was. Every measured
> figure now lives in `checks/doubled-words.py`'s docstring and nowhere else).
> Prior: 2026-07-29 (commit pending — first version, written after the
> `proseWrap` flip in #589 and the two clean-up passes it turned out to need,
> #590 and #591). If you change `settings.proseWrap`, add or swap a markdown
> formatter, or touch `checks/split-code-spans.*`, `checks/doubled-words.*` or
> `checks/markdown-scan.nix`, read this first.

A break landing MID-TOKEN is the one markdown defect in this repo that **no
check can catch**, so it has to be prevented at authoring time. Read the
qualifier: a break landing between two copies of the same word is a different
defect and IS caught — see `checks/doubled-words.nix` below. The unqualified
claim was true when written and became a trap once that check existed.

CommonMark replaces a newline inside an inline code span with a SPACE. Where the
break falls at a natural space that is harmless. Where it falls MID-TOKEN the
space lands inside an identifier and the rendered code is wrong:

    authored:   `programs.claude-code.
                marketplaces`
    renders as: programs.claude-code. marketplaces

Copy-pasting that yields a broken Nix attribute path. Prose outside code spans
has the same failure — `bun-` and `wrapper` split across a break render as
`bun- wrapper`.

**So: never end an authored line mid-identifier (on `.`, `/`, `-`, or `_`), and
never break inside a code span.** Put a long span on its own line and let it
overflow 80 columns — prettier does precisely that and will not split it.

#### Why there is no lint for it

The correct and incorrect forms are lexically identical; only context separates
them. `env // omEnv`, `nix-update --flake`, `<!-- header -->`,
`low / medium / high`, `pre- or post-` and `4- vs 5-value` are all correct,
while `repo- wide` and `cross- slice` are not. A "glue character followed by a
space" heuristic was measured across the tree: 96 hits, roughly 90% of them
legitimate. Shipping it would have been a check that cries wolf.

`checks/split-code-spans.nix` covers the adjacent case that IS decidable — a
span whose content still contains a newline. Its `.py` carries the CommonMark
backtick rule and why the obvious one-line regex is wrong.

#### The formatter launders new instances

Know this before trusting the guardrail: `proseWrap = "always"` joins a split
span by printing the span's CommonMark _value_, space included. It therefore
converts a newline `checks/split-code-spans.nix` would catch into a space that
nothing can. The window is narrow — nobody hand-wraps now that the formatter
owns wrapping — but it is not closed.

### The reflow also splits a doubled word — `checks/doubled-words.nix`

Same 80-column reflow, a different defect, and this one IS decidable. A word
repeated back to back (`is the the rootfs top level`, shipped in #878) is
invisible to all three of the tools you would expect to catch it: prettier
reflows the paragraph and reproduces the duplicate verbatim, cspell sees two
correctly spelled words, and the span check reasons about backticks.

The reflow is what makes it awkward rather than trivial. It decides which side
of a newline the pair lands on, so half the class looks like `the` / `the` on
two adjacent lines and a line-oriented regex never sees it. The scanner handles
both, and needs no paragraph reconstruction to do it: a doubled word is exactly
two tokens, so the only cross-line shape is the last token of one line against
the first token of the next.

Two things to know before touching it:

- **The false positives are tokenization bugs, not word-choice problems.** They
  come from masking a code span with spaces (which glues its neighbours:
  ``and `x` and`` reads as `and and`) and from treating the tail of a dotted
  identifier as a word (`settings.json JSON`). Both are fixed in the scanner. If
  precision decays, fix the tokenization — a stopword list would hide the next
  such bug instead of reporting it, and `and and` and `in in` are function words
  that would have survived one anyway. The measured hit counts behind all of
  that live in `checks/doubled-words.py`'s module docstring and nowhere else;
  read them there rather than trusting a number quoted in prose.
- **Suppression is per-file and visible in the source**, for the legitimate
  English cases (`had had`, `that that`) that this corpus happens not to contain
  yet:

  ```markdown
  <!-- doubled-words: allow had had -->
  ```

  On its own line — prettier keeps a standalone HTML comment as its own block,
  while one spliced into a paragraph gets reflowed away from what it points at.
  A marker that suppresses nothing fails the check, so a suppression cannot
  outlive the prose it was covering.

A third thing, which is really a `proseWrap` consequence and so belongs here
rather than only in the scanner: **the same reflow that splits the pair also
indents it.** Prettier wraps a nested bullet's continuation lines to four
columns, and a scanner that reads "four columns" as CommonMark's indented-code
marker deletes that prose before looking at it — silently, reporting the file
clean. Both scanners therefore measure indentation relative to the enclosing
list item's content column, not to column zero, and the same offset governs
fence recognition. If you touch `strip_code_blocks`, that is the invariant to
preserve; the measured cost of getting it wrong is in its docstring.

Both scans share their file set, exclusions and empty-set guard via
`checks/markdown-scan.nix`, and both scanners are assembled into one store
directory so the newer imports the CommonMark rule from the older. An empty file
set is a hard failure in both the Nix wrapper and each scanner's `main()`:
`find -print0 | xargs -0 -r` exits 0 on an empty tree, so a scan that received
nothing used to be indistinguishable from a passing one, and a guard living only
in one caller does not survive a second caller being added.

### Formatter selection is settled — do not re-survey

Measured 2026-07-29. Only prettier and mdformat join a split code span at all.
**No Rust-family markdown formatter does**, which is the intuition that usually
sends people looking for one:

| Tool                               | Joins a split code span?                      |
| ---------------------------------- | --------------------------------------------- |
| prettier `proseWrap: always`       | yes — treats a span as an unbreakable token   |
| mdformat `--wrap keep`             | yes, but does NOT rewrap → 110-160 char lines |
| dprint-markdown `textWrap: always` | NO — reflows around it, keeps the newline     |
| deno fmt                           | no — same engine as dprint                    |
| rumdl `fmt` / `check --fix`        | no — a markdownlint clone, no reflow          |

mdformat was rejected on output quality as much as on rewrap: it also escapes
`\<150` and wikilink brackets, and renumbers ordered lists.

### Two traps when validating a reflow

- **A pandoc before/after showing "renders identically" is NOT a safety
  signal.** For a mid-token span it proves the bug SURVIVED. #589 shipped
  claiming a fix it had not made because that output was read as reassurance.
- **`proseWrap` also governs YAML** folded and plain scalars, so a change to it
  reflows `.github/**` too. Verify by parsing both revisions and diffing the
  loaded structures, never by eye — a silently altered cache key or `if:`
  condition is invisible in review.
