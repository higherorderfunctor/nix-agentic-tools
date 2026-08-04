# Kiro corpus re-verification against 2.15.2 — running status

Branch `docs/kiro-corpus-drift-ledger`, worktree
`nix-agentic-tools-worktrees/kiro-corpus-drift-ledger`. Updated as work lands.

## The gate dissolved — I did not need to run the CLI

You gated "extracting the 2.15.2 bundle requires running the new CLI once". It
turns out it does not. **The KAS bundle is not downloaded — it is embedded in
the shipped chat binary**, as a gzip member named `kas-bundle.tar` inside
`.rodata`, and the CLI merely unpacks it on first run.

So the bundle was materialized into the session scratchpad by decompressing that
byte range directly. **Nothing under `~/.local/share/kiro-cli/` was written, no
Kiro process was started, and no network request was made.** The extraction was
a read of a file already in the nix store.

The directory-name scheme was settled with a positive control rather than
assumed: the suffix is the **sha256 of the compressed gzip member**, and hashing
2.15.1's member reproduces its existing directory name
(`e20633b4…fac12fc`) exactly. Applying the same method to 2.15.2 predicts

```
~/.local/share/kiro-cli/kas/2.15.2-7755e465057ad864a83fb445dbc6bfc63e77c5f2837adcb4a37913965ced7a8e
```

and the extracted member hashes to precisely that. Two independent derivations
agreed (string-neighbourhood position, and direct hashing).

**If you ever do run the CLI, that is the directory you should see appear.** It
is additive — extraction skips when the directory already exists, and never
touches the six older bundles.

One near-miss worth recording: the hash `81925c09…`, which sits right beside
`extracted KAS node runtime`, is **not** the KAS id — it is the embedded node
runtime, and it appears in the 2.15.1 binary too. Only a cross-version control
separated them.

## Headline finding — the workflow decoy became real at 2.15.2

R-workflow-8 ends by naming the single most valuable thing a re-run could check:
whether `isEnabled("workflows")` had appeared, or a `["workflows", …]` row had
joined the client's feature-to-setting table — either would mean the documented
but unconsumed feature flag had gained a consumer.

**Both have happened.**

- `isEnabled("workflows")`: **2 call sites** at 2.15.2, **0** at 2.15.1. Controls
  hold — `isEnabled("c2s")` is 2 and `isEnabled("remote_sandbox")` is 3 in both.
- The table is now
  `[["memory","memoryEnable"],["workflows","workflows"],["workflows","goal"]]`,
  where 2.15.1 had only the memory row.

Consequences, in descending order of how much they change a design:

1. `KIRO_ENABLED_FEATURES='["workflows"]'` should now **actually enable the
   workflow surface on a fresh session**. C-11 recorded the vendor's own
   instruction as inert; at 2.15.2 it is live.
2. That **supersedes R-workflow-2's persisted-metadata route** as the only way
   in. Seeding `workflowsEnabled: true` into a session file and resuming it is no
   longer necessary — which matters because the mode-F harness plans around
   exactly that seeding step.
3. Enabling the feature also switches on `goal`, not just `workflows` — one flag,
   two settings keys.
4. R-workflow-3's headline ("the settings builder omits the workflow key") is now
   **false**, though its narrower claim survives: there is still no
   `chat.enableWorkflows` config key. The route is the feature flag, not a config
   key, and keeping those apart is the whole precision of that record.

## The measurement environment moved too, and it is not the engine

`grep` on this machine is now **GNU grep 3.12**; the capture recorded **ugrep
7.5.0**. `find` is GNU findutils 4.10.0, not bfs. ugrep 7.8.2 exists in the store
but is on no `PATH` — login shell, devenv shell, or profile.

This matters because several record preambles state ugrep-specific semantics.
The corpus's chosen counting form survived the swap intact:

| form                            | 2.15.1 bundle | meaning         |
| ------------------------------- | ------------- | --------------- |
| `grep -c`                       | 5             | lines           |
| `grep -c -o`                     | 5             | lines (on GNU)  |
| `{ grep -boF … \| \| true; } \| wc -l` | **6**    | **occurrences** |

6 is the recorded value. So the `-bo | wc -l` convention reproduced the recorded
number **on a different grep implementation**, which is exactly what it was
chosen for. The stale part is the advice: a reader trusting "ugrep's `-c -o`
counts occurrences" would now silently get lines.

Separately: the interactive zsh alias is `grep -i --color=auto`. Case-insensitive
by default is a live hazard for records that turn on case (R-engine-1 explicitly
distinguishes `prePrompt` from `PrePrompt`). Aliases do not reach scripts, so the
records are safe, but a hand-run replay pasted into an interactive shell is not.

## Evidence records: 7 of 7 done

| record      | outcome        | note                                                                                     |
| ----------- | -------------- | ---------------------------------------------------------------------------------------- |
| R-machine-1 | reproduced     | 0 hook rows in sub-executions holds; controls 489 root hook rows / 11159 sub tool_calls   |
| R-machine-2 | reproduced     | 455 home-rooted + 34 workspace-rooted = 489, matching R-machine-1 independently           |
| R-machine-3 | reproduced     | layout, discriminator, and the 46/46 cross-check hold; the 38 exceptions stayed 38        |
| R-machine-4 | **changed**    | the "perfect co-presence" of `workflowsEnabled` with `_meta` is broken — now 194 / 1 / 26 |
| R-machine-5 | reproduced     | byte-identical: 19 / 7 / 19 / 0, same 16-3 agent split, same fan-out                      |
| R-machine-6 | reproduced     | all 8 upstream issue rows identical in state, reason, labels and title                    |
| R-machine-7 | **changed**    | see below — the resolver footgun stopped being hypothetical                               |

### R-machine-4 — the co-presence invariant broke

Recorded: 212 files, 18 carrying `workflowsEnabled`, and those 18 **exactly** the
18 carrying `_meta` — "perfect co-presence". Now: 221 files, 27 carrying the flag,
split **26 with `_meta` and 1 without**.

The record's primary claim is untouched — still **zero** sessions with the flag
`true`, so the surface has still never been switched on here. And its own stated
prediction held beautifully: the `ABSENT` bucket froze at exactly **194** across
both runs, which the record calls its strongest evidence that the bucket is
historical rather than current behaviour.

What broke is the sub-claim used to *date* the field. A reader trusting it would
conclude the two keys are written by one code path; they are not, and one session
now proves it.

### R-machine-7 — the footgun fired

At capture, lexical-last and newest-by-mtime "happen to be correct today, which
is what makes them dangerous". They are now **wrong**: both select **2.15.1**
while the CLI is **2.15.2**. The predicted silent failure has actually occurred.

Also: seven KAS directories became **six** — 2.12.1 disappeared, so the set is
not append-only. Lexical-first now picks 2.12.3, five releases behind rather than
six. The version-pinned resolver correctly refuses with `found 0`.

And the stale 2.13.0 agent server is **still running**, now at **611774 s
(7.1 days)**, still parented to `systemd --user`. It has survived five CLI
upgrades. No 2.15.x process is live at all.

## What is still running

A workflow is replaying the 35 bundle-side records across the five record files,
with an adversarial refutation pass over every `changed`/`removed` outcome.

## Notes for the writeup

- The prompt says the negatives run "C-1 through C-15". The file ends at **C-14**;
  there is no C-15. Corpus totals are 42 records + 7 evidence + 14 negatives.
- C-11 ("documented capability with no implementation behind it") is now
  historically true but no longer current — the workflow flag gained its consumer.
  That needs a dated note rather than a deletion.
- Candidate new negative: the KAS id is the hash of the *compressed* member, and
  the neighbouring runtime hash reads exactly like it. Worth carrying.

## Review loop — PR #615

**Round 1 (head `34c29500`)** — all six checks green. Copilot review present with a
matching `commit_id`. Two gating threads, **both genuine**, no suppressed findings
(confirmed by positive control: body was 2102 bytes with one `<details>`, the
per-file summary, and it said "generated 2 comments" matching the two threads).

1. The narrative said the refutation pass meant "two records changed rather than
   four" while the table said four. The table was right; the prose conflated the
   code-read subset with the section total. Fixed in `c0ec60d`.
2. The `Drift:` example in the format spec pointed at `drift-ledger.md`, but
   stamps live one directory down, so a reader copying it would write a path that
   does not resolve. Every real stamp already used `../drift-ledger.md`. Fixed.

Both threads replied to and resolved. **0 unresolved.**

**Round 2 (head `c0ec60d`)** — the push did NOT auto-trigger a review (check-run
absent by name, which is the tell), so it was re-requested. It then came back
**clean in both buckets**: zero unresolved threads, and a review body that says
"generated no new comments" outright — checked rather than inferred from an empty
grep, since a short body and a broken query look identical.

**Loop closed at 2 of 5 rounds** on the early-exit condition. PR #615 is
`mergeable_state=clean`, all four required checks green, 2 threads / 0 unresolved,
3 commits, +642/-5. **Handed over for the squash merge** — the operator performs
merges for human PRs.
