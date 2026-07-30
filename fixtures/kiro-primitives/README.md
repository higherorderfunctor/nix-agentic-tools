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
anchors are minified identifiers that churn on every release, nothing consumes
the output at build time, and the access pattern is "months later, someone asks
whether this still holds". A recorded command answers that question exactly as
well as a check would, without a lint that cries wolf on cosmetic renames. What
survives instead is the **semantic anchor**: each record describes what the code
_does_, in words, so it can be relocated even after every identifier is renamed.
**The command is disposable; the semantics are not.**

## Layout

| Path                   | Mode  | Contents                                                    |
| ---------------------- | ----- | ----------------------------------------------------------- |
| `records/*.md`         | **R** | code-read records against the engine bundle                 |
| `evidence/*.md`        | **R** | measurements over this machine's own Kiro state             |
| `carried-negatives.md` | **C** | beliefs that were wrong, and **how each mistake presented** |

Mode **F** — runnable fixtures needing a live interactive session — is planned
and not present yet. The engine does not run under a non-interactive shell, so
those cannot be automated and must be operator-driven.

**Start with `carried-negatives.md` if you are new here.** The expensive part of
an undocumented engine is rarely the discovery — it is the wrong turn taken
first, and that file is the list of wrong turns already paid for.

## Before re-running anything: pin the bundle

**This is the single most important operational detail.** Several engine
versions accumulate side by side, and a naive glob silently selects the wrong
one — lexical-first picks a bundle six releases behind, while lexical-last and
newest-by-mtime happen to be correct _today_, which is what makes it dangerous.
Resolve by the CLI's own version and assert exactly one match:

```bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
ver=$(kiro-cli --version | awk '{print $NF}')
matches=$(ls -d "$HOME/.local/share/kiro-cli/kas/${ver}-"*/ | wc -l)
[ "$matches" -eq 1 ] || { echo "ambiguous engine bundle - refuse"; exit 1; }
kas=$(ls -d "$HOME/.local/share/kiro-cli/kas/${ver}-"*/)
bundle="${kas}node_modules/@kiro/agent/dist/server/acp-server.js"
kasid=$(basename "${kas%/}")
```

The bundle is ~20 MB and effectively single-line. **Never `cat` it, never read
it into a variable, and never pipe it whole through a language runtime** — that
is an out-of-memory risk. Use bounded windows only:

```bash
grep -boF 'needle' "$bundle" | head
tail -c +$((OFFSET-300)) "$bundle" | head -c 1200
```

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

## Two rules that every record follows

- **Every asserted absence names positive controls** — strings confirmed
  _present_ by the same method. Without them, "the feature is gone" and "the
  bundle moved and my search no longer parses it" are indistinguishable, and the
  second silently reads as the first.
- **Every count names its denominator.** Zero occurrences means nothing unless
  the same files are shown to record that kind of event at all.

## Notes for maintainers

- `records/` and `evidence/` are excluded from spell-checking: they quote
  verbatim minified identifiers and real command output, including fragments cut
  mid-token by windowed extraction. Authored prose (this file,
  `carried-negatives.md`) **is** checked.
- Findings are version-scoped. A CLI update ships a new engine bundle and can
  move any of them; that is expected, and the resolver plus the per-record
  version stamp is how you find out which.
