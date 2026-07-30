# Drift ledger

What changed between engine versions, when it changed, and whether each record
in this corpus is still true.

Every record carries a **Verified against** stamp naming the bundle its recorded
output came from. That stamp answers one question — _was this true once_ — and
it cannot answer the two that matter months later: _what changed_, and _is it
still true_. Re-verifying without somewhere to put the answer produces a
conversation rather than a record, and the next reader inherits neither.

This file is that somewhere. It accumulates.

## The two halves, and why the work is split this way

Drift is recorded in two places, and neither repeats the other's content.

**Per record, a one-line `Drift:` series.** Appended below the existing
`Verified against` stamp, one clause per version checked:

```text
**Drift:** 2.15.2 reproduced
**Drift:** 2.15.2 reproduced · 2.16.0 relocated · 2.16.1 changed — see `drift-ledger.md`
```

It answers "I am reading this record right now; is it still true?" without
leaving the file. It carries the outcome word and nothing else — no rationale,
no numbers.

**Here, one section per version transition.** Every record's outcome in one
table, with the denominator, followed by prose for each row that is not
`reproduced`.

It answers "what changed in 2.15.2?" in a single read.

### Why not a history table on every record

A per-record history table was the obvious alternative and it is the wrong
shape, for three reasons that compound.

The outcome distribution is overwhelmingly `reproduced`. A release that moves
two records leaves forty untouched, so forty tables would exist to carry two
bits — and worse, the two interesting rows would be visually identical to the
forty boring ones, spread across five files. The signal is the exception, and a
format that renders exceptions the same way as the rule hides them.

The question a re-verification is actually asked is release-shaped, not
record-shaped. "What moved in 2.15.2, and does it break anything downstream?" A
ledger answers that in one read; forty tables answer it only after forty reads
and a manual join.

A real finding needs prose — what was believed, what is now true, how the
difference would have presented, what it invalidates. That does not fit a table
cell, and putting it inline would bury each record's own claim under its
changelog. Records state what the engine does. The ledger states what happened
to that statement.

What a ledger alone cannot do is tell you, while you are reading R-limits-1,
whether R-limits-1 still holds. Hence the one-line stamp. It is one line, it
grows by one clause per release, and it pays for itself twice — see the omission
check below.

## The five outcomes

A closed vocabulary. Use these words exactly; a sixth word makes the series
impossible to grep.

| Outcome          | Meaning                                                                                                         |
| ---------------- | --------------------------------------------------------------------------------------------------------------- |
| **reproduced**   | The recorded commands produce the recorded output byte for byte.                                                |
| **relocated**    | Offsets or generated identifiers moved, the semantic anchor found the thing anyway, and the claim is unchanged. |
| **changed**      | The behavior itself differs. A real finding, and the most valuable row in any section.                          |
| **removed**      | The thing is gone. Requires positive controls — see below.                                                      |
| **unverifiable** | Could not be checked this run. Always name why, in parentheses.                                                 |

**The outcome is per record, not per command block.** Each `R-*` establishes one
claim; its several command blocks are evidence for that one claim. When some
blocks reproduce and others move while the claim survives, that is precisely
what `relocated` means — do not split a record into two outcomes. When the claim
itself no longer holds, the record is `changed` however many of its blocks still
match.

`relocated` is the expected outcome for most records on most releases, because
byte offsets are rebuilt every release and esbuild's collision suffixes churn.
Reserve `reproduced` for a genuine byte-for-byte match; using it loosely turns
the one outcome that means "nothing moved at all" into noise.

## Two rules carry over unchanged

Both are load-bearing here for the same reason they are load-bearing in the
records.

**`removed` requires positive controls.** An asserted absence must name strings
confirmed _present_ by the same method in the same run. Without them, "the
feature is gone" and "the bundle moved and my search no longer parses it" are
the same observation, and the second silently reads as the first. Every record
that asserts an absence already ships a control block; re-run it, and record the
control values in the finding. If the controls collapse toward zero, the outcome
is `unverifiable`, not `removed`.

**Every count names its denominator.** A section's table must account for every
record in the corpus — outcomes summing to the total, with the total stated. A
section that lists nine rows out of forty-two is not a partial answer, it is an
unmarked one: the thirty-three unlisted records read as fine when they were
never looked at.

## Evidence records measure live state, so the words mean something narrower

`evidence/*.md` measures this machine rather than a shipped artifact, and drifts
by design. Two adjustments, both of which would otherwise be filled in
differently by two people:

**`reproduced` means the load-bearing figure and its controls still hold**, not
that the numbers are identical. Several evidence records already name which of
their figures is load-bearing and which is context; honour that distinction. A
session count that grew is not a change.

**Stamp what produced the state, not just what is installed.** A transcript
corpus written by 2.15.1 does not become a 2.15.2 observation because 2.15.2 is
now on `PATH`. Where a record's subject is machine state accumulated over time,
say so, and reserve the version stamp for what was actually running. Where its
subject is the current installation — the bundle census, for instance — the
installed version is the right stamp.

## The omission check

There is deliberately no extractor and no automated drift check in this corpus,
and adding one is not the fix here: the anchors renumber every release and
nothing consumes the output at build time. But omission is the one failure a
ledger can suffer silently, so it gets a check that needs no tooling.

Per file, the number of `**Drift:**` stamps must equal the number of `## R-`
headings once a version has been swept:

```bash
for f in records/*.md evidence/*.md; do
  printf '%-40s records=%-3s stamps=%s\n' "$f" \
    "$({ grep -c '^## R-' "$f" || true; })" \
    "$({ grep -c '^\*\*Drift:\*\*' "$f" || true; })"
done
```

Unequal means a record was skipped, not that it passed. That is the whole reason
the per-record stamp earns its line.

Grepping the series answers the release-shaped questions directly —
`grep -rn '2\.15\.2 changed' records/ evidence/` lists every record whose
behavior moved at that version.

## A note on spelling and quotation

`records/**` and `evidence/**` are excluded from spell-checking because they
quote verbatim bundle identifiers and windowed command output cut mid-token.
**This file is not excluded**, and that is deliberate: it is authored prose, and
holding it to the same discipline as `carried-negatives.md` — describe the
mechanism, quote sparingly — is what keeps a drift log readable rather than
turning it into a second copy of the records. Where a finding genuinely needs a
verbatim identifier, the identifier belongs in the record, and the finding here
points at it.

## Adding a section

Newest first, so the most recent sweep is the first thing read. A section
carries, in order: the bundle identity and date, what was and was not checked,
the outcome table with its denominator, and one prose subsection per
non-`reproduced` row headed by the record id.

A finding follows the shape the corpus uses everywhere else, because it is the
shape that saves the next reader the diagnosis rather than only the answer: what
was believed, what is now true, **how the difference would have presented** to
someone trusting the old record, and whether it invalidates a downstream
decision.

If a change deserves a new carried negative, add it to `carried-negatives.md` in
the existing four-field form and reference it from the finding.
