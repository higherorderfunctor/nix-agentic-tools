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

Sections follow, newest first.

---

# 2.15.1 → 2.15.2

Swept 2026-07-30. Engine bundle
`2.15.2-7755e465057ad864a83fb445dbc6bfc63e77c5f2837adcb4a37913965ced7a8e`,
20758819 bytes (2.15.1 was 20752757). CLI binaries from kiro-cli 2.15.2:
launcher 53825384, chat 555376840, terminal helper 41766592 bytes — each
slightly larger than its 2.15.1 counterpart, all three of which are still in the
store and were used as the differential baseline throughout.

## How the bundle was obtained, and why that matters

**No CLI was run and no machine state was written.** The engine bundle is not
downloaded — it ships inside the chat binary as a compressed archive member, and
the CLI merely unpacks it on first launch. It was therefore materialized into a
scratch directory by decompressing that byte range directly out of the store.

The naming scheme was established by **reproducing a value already known**
rather than by deriving one and checking that it looked right: the directory
suffix is the hash of the **compressed** member, and hashing 2.15.1's member
returns exactly the suffix of its existing directory. The same method applied to
2.15.2 predicts the id above, and the extracted member hashes to it.

This matters beyond convenience. It means a bundle can be read for any release
whose binary is still in the store, **without installing it and without running
it** — so a future sweep can be differential against several releases at once,
which is what settled two of this sweep's four disputed outcomes.

Two traps were hit and are recorded as [C-15](carried-negatives.md) and
[C-16](carried-negatives.md): the binary interns several same-shaped hashes and
the wrong one sits closer to the extraction machinery, and the search tooling
named in every record preamble is no longer the tooling on this machine.

## What was checked, and what was not

All **42** records were swept: 35 code-read records against the new bundle and
the 2.15.2 binaries, and 7 machine-state records against this machine.

Not checked: the mode-F fixtures, which need an operator-driven sitting and were
out of scope. Nothing was marked `unverifiable` — every record was reachable.

Each outcome that came back `changed` was then handed to an independent reviewer
whose instructions were to **refute** it, with a standing instruction to prefer
`relocated` when only offsets and generated identifiers had moved. **Two of the
four survived; two were overturned** and appear below as `relocated` with the
sub-claim damage recorded as a note. That pass is the reason this section says
two records changed rather than four, and it is worth keeping.

## Outcomes

| Outcome      | Count  |
| ------------ | ------ |
| reproduced   | 6      |
| relocated    | 32     |
| changed      | 4      |
| removed      | 0      |
| unverifiable | 0      |
| **total**    | **42** |

| Record          | Outcome        | Note                                                                       |
| --------------- | -------------- | -------------------------------------------------------------------------- |
| R-concurrency-1 | relocated      | every bundle offset moved by exactly +1561; both constants still 5         |
| R-concurrency-2 | relocated      | still one production call site; semaphore still per-execution              |
| R-nesting-1     | relocated      | gate still `>=`, still returned not thrown, literal still 5                |
| R-nesting-2     | relocated      | still one construction site carrying `currentDepth + 1`                    |
| R-nesting-3     | relocated      | still two depth comparisons total; all identity predicates still 0         |
| R-hooks-1       | relocated      | still 11 canonical triggers and 27 table keys                              |
| R-hooks-2       | relocated      | still no subagent-lifecycle trigger; the same 11 hits reclassify           |
| R-hooks-3       | relocated      | still two node roles, three guarded bodies                                 |
| R-hooks-4       | relocated      | first-turn rule and dispatch pinning unchanged                             |
| R-hooks-5       | relocated      | `dispatchKind` unlock intact; adapters still differ only in the skip flag  |
| R-hooks-6       | relocated      | tool and file hook call sites still carry no skip check                    |
| R-hooks-7       | relocated      | child still shares services, workspace and session id by reference         |
| R-hookio-1      | relocated      | still 11 switch arms plus the confirm-command builder                      |
| R-hookio-2      | relocated      | still `env: {}` over `process.env`; default timeout still 60               |
| R-hookio-3      | relocated      | **the dropped-parameter defect is still present** — the fix has not landed |
| R-hookio-4      | relocated      | decision function and both bypasses unchanged                              |
| R-hookio-5      | relocated      | still ask-only; no-handler default still denies                            |
| R-hookio-6      | relocated      | exit 1 still restarts the graph; cap still 4000                            |
| R-hookio-7      | relocated      | home directory still a global hook root                                    |
| R-hookio-8      | relocated      | **the symlink trap is still open** — still no diagnostic                   |
| R-hookio-9      | relocated      | both gates unchanged                                                       |
| R-limits-1      | relocated      | iteration limit still 300; reset path unchanged                            |
| R-limits-2      | relocated      | still `{recursionLimit, signal}` on all four entry points                  |
| R-limits-3      | relocated      | **thresholds still 80/95 and the scoping is unfixed**                      |
| R-limits-4      | relocated      | still an in-process object; no spawn primitive on the path                 |
| R-limits-5      | relocated      | claim holds; two sub-claims damaged — see note below                       |
| R-engine-1      | relocated      | headline correction intact; row group A damaged — see note below           |
| R-workflow-1    | **reproduced** | byte for byte, offsets included                                            |
| R-workflow-2    | relocated      | persisted route still works, but is no longer the only one                 |
| R-workflow-3    | **changed**    | the client now sends the workflow key                                      |
| R-workflow-4    | relocated      | registration still all-or-nothing, still six tools                         |
| R-workflow-5    | relocated      | every enum and ceiling unchanged; `any` still cancels                      |
| R-workflow-6    | relocated      | the schema/description drift is unchanged                                  |
| R-workflow-7    | relocated      | still seven recipes; `ralph` still ships `pause`                           |
| R-workflow-8    | **changed**    | the decoy gained a consumer                                                |
| R-machine-1     | reproduced     | zero hook rows in sub-executions holds; controls fired                     |
| R-machine-2     | reproduced     | 455 + 34 = 489, matching R-machine-1 independently                         |
| R-machine-3     | reproduced     | layout, discriminator and the 46/46 cross-check hold                       |
| R-machine-4     | **changed**    | the co-presence invariant broke                                            |
| R-machine-5     | reproduced     | byte-identical; the nested corpus is still static                          |
| R-machine-6     | reproduced     | all eight upstream rows identical                                          |
| R-machine-7     | **changed**    | the resolver footgun stopped being hypothetical                            |

Thirty of the thirty-two `relocated` rows moved by a uniform offset shift with
no other difference. That uniformity is itself worth recording: it means the
release added code in a few places rather than restructuring, and it is why a
differential read against the previous binary was so much cheaper than
re-deriving each anchor.

---

## R-workflow-3 — changed: the client now sends the workflow key

**Believed:** the shipped client's settings builder had a fixed allowlist in
which the workflow key appeared nowhere — not in the config-key pairs, not in
the defaults, not in the one-row feature-to-setting table — and no user-facing
config key mapped to it. The gate therefore saw nothing and floored to off on
every fresh session.

**Now true:** the feature-to-setting table grew from one row to three, and two
of the new rows are driven by the workflow feature — enabling it emits **both**
the workflow setting and the goal setting. So a client with that feature enabled
now sends the payload the engine has always been willing to accept.

The record's own staleness trigger was "the moment a config key or a workflow
pair appears". **Half of it fired**: the pair appeared, the config key still
does not exist. That distinction is the record's whole precision and it survives
— the route is the feature flag, not a config key.

**How it would have presented:** as `unchanged`. The recorded control window is
anchored on a log string that moved by ~19.7 KB; replaying at the recorded
offset returns zero for the workflow key — and also zero for two controls that
must be non-zero. The record explicitly says a collapsed control row means the
window drifted off the builder rather than that the string is absent.
**Reporting the shifted window without reading its own controls would have
certified a claim that had just been reversed.** This is the single strongest
argument in this sweep for re-running control blocks rather than eyeballing a
diff.

**Invalidates:** this record's headline; R-workflow-2's corollary that the
persisted route is "not merely a path, it is the only path available without
patching a binary"; and R-workflow-8's correction.

## R-workflow-8 — changed: the decoy gained a consumer

**Believed:** no environment variable enables the workflow gate. The engine half
was clean, and the client's shipped experiment catalog carried an entry whose
own description told the reader to enable it through an environment variable —
but that entry had **no consumer**, making the vendor's own instruction inert.
This was recorded as C-11.

**Now true:** the engine half is unchanged in every particular, down to the
counts. The **client** half reversed. The feature predicate now has two call
sites where it had none, the feature-to-setting table carries workflow rows, and
seven slash commands are now gated on the workflow feature where previously only
one command carried a feature gate at all.

So the environment variable now works. The catalog entry's text and its zero
treatment percentage are unchanged, so it remains opt-in — but it is no longer a
decoy.

**This record predicted its own obsolescence and named the exact check.** Its
closing note calls this "the single most valuable thing a re-run can check", and
lists two triggers. Both fired.

**How it would have presented:** as `unchanged`, in two independent ways. A
replay of only the engine half passes perfectly. And the recorded command greps
for the table by its **generated handle**, which was renamed — so it returns
nothing, and the `|| true` that protects against a legitimate zero converts the
rename into a silent empty line rather than an error. Searching for the table by
**content** is what surfaces it. That is a general lesson: a generated handle is
not just an unreliable anchor, it is an anchor whose failure looks like a
negative result.

**Invalidates:** its own correction paragraph, and C-11 as current behavior.
C-11 now carries a dated update rather than being deleted — the transition it
brackets is more useful than either endpoint.

## R-machine-4 — changed: the co-presence invariant broke

**Believed:** every session file carrying the workflow-enable flag also carried
the metadata wrapper key, exactly and without exception — "perfect co-presence"
— which dated the field to a single schema revision.

**Now true:** one session carries the flag **without** the wrapper. The buckets
are 194 with neither, 26 with both, 1 with only the flag.

**The record's primary claim is untouched and its own prediction held
beautifully.** No session is `true`, so the surface has still never been
switched on here; and the record's stated signature — that the "absent" bucket
is historical and should stay frozen while the others grow — held to the digit,
at exactly **194** across both runs, while the populated bucket grew from 18
to 27.

**How it would have presented:** as a rounding detail. Someone reading the
co-presence claim would conclude the two keys are written by one code path and
could be used interchangeably as a probe for the other. One session now
disproves that, and a fixture keying on the wrapper to detect the flag would
silently miss it.

**Invalidates:** the co-presence sub-claim only. The record should keep its
primary finding and demote that sentence to a dated observation.

## R-machine-7 — changed: the resolver footgun stopped being hypothetical

**Believed:** of the naive bundle resolvers, lexical-first is badly wrong while
lexical-last and newest-by-mtime "happen to be correct _today_, which is what
makes them dangerous".

**Now true:** they are wrong. Both select **2.15.1** while the CLI reports
**2.15.2**. The predicted silent failure has actually occurred, and a replay
using either would read a one-release-stale bundle while reporting success.

Three further movements in the same record:

- Seven installed bundles became **six** — one release disappeared, so the set
  is **not append-only**. Lexical-first is now five releases behind rather than
  six.
- The version-pinned resolver refuses correctly, with a count of zero, which is
  the designed behavior on a machine whose CLI has been updated but whose bundle
  has not been unpacked.
- The stale agent server is **still running**, now past **seven days**, still
  adopted by the user's init process. It has survived five CLI upgrades.

**How it would have presented:** silently and plausibly. A resolver picking the
previous release returns a real directory containing most of the same strings,
so a sweep using it would produce output that looks correct and is one release
out of date — which is precisely the failure the record was written to prevent,
now demonstrated rather than predicted.

**Invalidates:** nothing downstream. It **upgrades** the record from a warning
to a demonstration, which is the most useful thing that can happen to a warning.

---

## Notes on two records that were nearly miscalled

Both were reported `changed` on the first pass and overturned on review. They
are recorded here because the sub-claim damage is real even though the outcome
was not, and because the way each nearly went wrong is reusable.

**R-limits-5.** The builder now forwards a settings member that is in neither
the allowlist nor the typed sub-option blocks, so the semantic anchor's closing
sentence — "anything not in that array or those four blocks is not forwarded" —
is now inaccurate, and the recorded count of distinct keys should be labelled
for what it always was: a census of keys spelled as **literals** in that window,
not of keys the builder reads. A key referenced through a symbolic constant is
invisible to that regex. The load-bearing negative is untouched: the new member
is a notification-routing flag, not a work budget, and every absence row is
still zero. It also **extends** the record's own secondary finding — the new
member is read nowhere in the engine, making it a third
declared-and-forwarded-but-inert setting, and the first that is brand new.

The reviewer settled it by enumerating the client's entire settings-key constant
table at two window sizes and diffing it against the previous release in both
directions: empty both ways. That is a much stronger test than the record's ten
guessed needles, and it is the method a future sweep should use.

**R-engine-1.** Three workflow needles went from zero to non-zero in the chat
binary, which fires the record's stated staleness trigger verbatim ("goes stale
if a workflow name appears in any Rust binary") and looks like a clean
inversion. It is not. Every new hit sits in the binary's embedded client
JavaScript, roughly sixty times deeper into the file than the last Rust source
path; the surrounding bytes are unmistakably minified JS. The record's own
discriminator is **region-scoped**, its conventions section mandates classifying
a hit in this binary by its neighborhood, and it already tolerated a non-zero
hit of exactly this kind at capture.

The reviewer also ran a completeness check the first pass had not: broadening to
the bare token across the whole binary finds dozens of Rust-region hits — with
**identical counts at both releases** and a uniform offset shift — all of them
unrelated service action names and English prose in embedded prompt text. There
is no Rust-region delta at all. The three machinery needles that would actually
matter are still zero.

So the correct, smaller claim is that **the v3 client grew a workflow surface**,
which is the client-side face of the same change R-workflow-3 and R-workflow-8
record. What should be edited is the record's loose file-level phrasing in one
bullet, tightened to the region-scoped wording the rest of it already uses.

**The general lesson, and the reason the refutation pass earned its cost:** a
fired staleness trigger is a prompt to classify, not a verdict. Both records
named the correct trigger and both triggers fired; in neither case did the claim
break. A sweep that treated a trigger as a verdict would have reported four
changes, two of them wrong, and would have sent someone editing a record whose
durable correction was never in doubt.
