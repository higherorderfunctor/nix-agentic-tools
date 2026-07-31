# Kiro CLI v3 primitive corpus

A **replayable** record of how the Kiro CLI v3 engine actually behaves —
subagent dispatch and concurrency, nesting, the workflow surface, hook firing
and I/O, and per-execution limits.

Almost none of this is documented upstream. It was established by reading the
shipped engine bundle and this machine's own session state, and several findings
**contradict the vendor documentation**. The corpus exists so that work is not
repeated.

## Why "replayable" rather than "tested"

Every record carries **a command that was actually executed and its real
output**. A record built from memory is prose wearing a command's clothes, so
the discipline is: if you cannot run it, it is not a record.

Deliberately, there is **no extractor and no automated drift check**. The
anchors are generated identifiers that renumber on every release, nothing
consumes the output at build time, and the access pattern is "months later,
someone asks whether this still holds". A recorded command answers that question
exactly as well as a check would, without a lint that cries wolf on cosmetic
renames. What survives instead is the **semantic anchor**: each record describes
what the code _does_, in words, so it can be relocated even after every
identifier is renamed. **The command is disposable; the semantics are not.**

## Layout

| Path                   | Mode  | Contents                                                      |
| ---------------------- | ----- | ------------------------------------------------------------- |
| `records/*.md`         | **R** | code-read records against the engine bundle                   |
| `evidence/*.md`        | **R** | measurements over this machine's own Kiro state               |
| `carried-negatives.md` | **C** | beliefs that were wrong, and **how each mistake presented**   |
| `drift-ledger.md`      | **D** | what changed between engine versions, when, and what it broke |
| `harness/`             | **F** | the ACP driver, the scratch environment, the run-state bridge |
| `workflows/`           | **F** | generated workflow definitions and a standalone validator     |
| `queue/`, `scripts/`   | **F** | the synthetic work queue and its claim/verify tooling         |

Mode **F** — runnable fixtures — **exists as of 2026-07-31**, and the premise
this section used to state is retired. It said the fixtures "cannot be automated
and must be operator-driven", because the engine does not run under a
non-interactive shell. The first half does not follow from the second: the
engine delegates authentication to the ACP **client**, so a host that answers
`_kiro/auth/getAccessToken` runs it headless — no TUI, no terminal, no operator.
`harness/acp-drain.py` drives a workflow to completion that way, and
`evidence/drain-live-runs.md` is the first live evidence in this corpus.

What remains genuinely operator-driven is narrower than "mode F": the sittings
in `RUNBOOK-session-b.md` and `RUNBOOK-session-c.md`, which probe hook firing,
nesting and MCP wiring through the interactive client.

**Start with `carried-negatives.md` if you are new here.** The expensive part of
an undocumented engine is rarely the discovery — it is the wrong turn taken
first, and that file is the list of wrong turns already paid for.

## These snippets require bash

Every command block here is written for **bash**, and the strict-mode constructs
are bash-only: `shopt` is not a zsh builtin, and bash's `nullglob` makes a
non-matching glob expand to nothing where zsh instead treats it as a hard error.
Run them under `bash` rather than an interactive zsh or fish — otherwise a
resolver either reports the wrong thing or dies before reaching its own refusal
path. This bit me during review: my first attempt to verify a finding here ran
under zsh and produced a misleading result.

**Bash, but not GNU.** This repo builds on `aarch64-darwin` as well as Linux, so
a coreutils extension is a portability bug in the **harness code** even though
every fixture here has only ever been run on Linux. Three have been found, all
the same shape — a construct that works so reliably on the author's machine that
nothing prompts a second look:

- `find -printf` is GNU-only and absent on darwin (`kiro_newest_log` sorts log
  paths lexically instead).
- `mktemp` and `mktemp -d` **require an explicit template on BSD/macOS**. GNU
  supplies a default and succeeds; BSD errors out. Harness call sites pass
  `mktemp -d "${TMPDIR:-/tmp}/<name>.XXXXXX"`.
- `kiro_bucket` was GNU-only in **three places at once** — `sort -z`,
  `head -c -1` and `sha256sum` — any one of which would stop a darwin operator
  computing a bucket name at all. It is now one `python3` call, which the
  fixtures already require, and `self-test-bucket.sh` proves the hash is
  unchanged by re-deriving every real bucket on the machine.

**The distinction that matters: executable harness code versus recorded
snippets.** The rule above binds `harness/`, `scripts/` and `workflows/`, which
have to RUN. It deliberately does **not** bind the command blocks inside
`records/` and `evidence/` — several of those use a bare `mktemp` and would fail
on darwin as written.

Those are not call sites, they are **transcripts**: this corpus's whole premise
is that a record carries a command that was actually executed together with its
real output, so editing them into portable form would make them commands nobody
ran. The record would look better and be worth less. They are left exactly as
executed, and a darwin reader should expect to adapt them rather than paste
them.

None of this is caught by anything: shellcheck has no diagnostic for any of it,
and the Linux CI leg passes regardless. They are review obligations.

## Before re-running anything: pin the bundle

**This is the single most important operational detail.** Several engine
versions accumulate side by side, and a naive glob silently selects the wrong
one — lexical-first picks a bundle six releases behind, while lexical-last and
newest-by-mtime happen to be correct _today_, which is what makes it dangerous.
Resolve by the CLI's own version and assert exactly one match.

Note the `nullglob` + array form rather than `ls … | wc -l`: under `set -e` +
`pipefail`, a non-matching glob makes `ls` fail and aborts the block **before**
the refusal check can run, so you get `ls: cannot access …` instead of the
intended message. Zero matches is a real case — a machine where the CLI has been
updated but its engine bundle not yet extracted.

```bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
ver=$(kiro-cli --version | awk '{print $NF}')
shopt -s nullglob
kasdirs=( "$HOME/.local/share/kiro-cli/kas/${ver}-"*/ )
[ "${#kasdirs[@]}" -eq 1 ] || { echo "ambiguous engine bundle - refuse (found ${#kasdirs[@]})"; exit 1; }
kas="${kasdirs[0]}"
bundle="${kas}node_modules/@kiro/agent/dist/server/acp-server.js"
kasid=$(basename "${kas%/}")
```

The bundle is ~20 MB. **Never `cat` it, never read it into a variable, and never
pipe it whole through a language runtime** — that is an out-of-memory risk. Use
bounded windows only:

```bash
grep -boF 'needle' "$bundle" | head
head -c $((OFFSET + 1200)) "$bundle" | tail -c 1500
```

Two properties of the bundle worth knowing before you start, because both are
easy to get backwards:

- **It is not identifier-minified.** It is esbuild-bundled but
  **pretty-printed** (~495k lines), keeps `// src/<path>.ts` section markers,
  and keeps original names and comments — so line-oriented tooling and editor
  navigation do work. Note one line exceeds 180 KB, which is what makes a naive
  whole-file read expensive despite the pretty-printing. What _does_ churn
  between releases is esbuild's **collision suffixes** (`state2`, `graph2`,
  `resolve24`), which is why those handles are untrustworthy as anchors even
  though they are not minifier output.
- **Prefer `head … | tail …` over `tail -c +N … | head -c M`.** The records use
  the former. The stated reason is that giving `head` cause to close the pipe
  early can surface as a SIGPIPE on `tail` and fail the pipeline under
  `pipefail` — though see the correction note in
  `records/concurrency-and-nesting.md`: that failure did **not** reproduce on
  GNU coreutils 9.11, so treat the preference as a portability hedge rather than
  an observed failure on this machine.

## Re-verifying the corpus

1. Resolve the bundle as above and compare `kasid` against the version stamped
   in each record's **Verified against** field.
2. If it matches, the records should reproduce byte-for-byte. Anything that does
   not is a finding — correct the record.
3. If it differs, expect drift. Re-run the commands and treat each mismatch as a
   question, not a failure: the **semantic anchor** tells you what to look for
   even when the identifier has been renamed.
4. Measurements over machine state (`evidence/`) drift by design — they are
   stamped snapshots of a live corpus, not constants.
5. **Record an outcome per record in `drift-ledger.md`, and stamp the record
   itself.** Read that file before starting: it fixes the outcome vocabulary
   (reproduced, relocated, changed, removed, unverifiable), says what each word
   means for a live measurement as opposed to a code read, and carries the check
   that catches a record you skipped. A sweep that corrects records without
   writing the ledger loses the only thing that makes the next sweep cheaper.

## Two rules that every record follows

- **Every asserted absence names positive controls** — strings confirmed
  _present_ by the same method. Without them, "the feature is gone" and "the
  bundle moved and my search no longer parses it" are indistinguishable, and the
  second silently reads as the first.
- **Every count names its denominator.** Zero occurrences means nothing unless
  the same files are shown to record that kind of event at all.

## Notes for maintainers

- `records/` and `evidence/` are excluded from spell-checking: they quote
  verbatim bundle identifiers and real command output, including fragments cut
  mid-token by windowed extraction. Authored prose (this file,
  `carried-negatives.md`) **is** checked.
- Findings are version-scoped. A CLI update ships a new engine bundle and can
  move any of them; that is expected, and the resolver plus the per-record
  version stamp is how you find out which.
