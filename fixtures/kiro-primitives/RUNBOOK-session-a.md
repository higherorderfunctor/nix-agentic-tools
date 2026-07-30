# Runbook — Session A: the workflow surface

Mode **F**: an interactive sitting. The v3 engine does not run under a
non-interactive shell, so these steps cannot be automated — the operator drives
each one and reads the result before the next.

**This runbook is self-contained on purpose.** Every step states the command,
the expected output, and **what a wrong result means**. You should not need to
read a design document mid-sitting.

## Before you start

| Precondition                          | Why                                                                                                                                                                                                 |
| ------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| The machine has logged in to Kiro     | The harness isolates `HOME` but deliberately leaves `XDG_DATA_HOME` real. An empty credential store makes the CLI open a **browser login** instead of failing.                                      |
| Every command block is run under bash | `shopt` is not a zsh builtin, and a non-matching glob is a hard error in zsh where bash expands it to nothing. This has already produced one wrong result here.                                     |
| No second `devenv shell` entry        | A second entry in one worktree leaves a stale `commit-msg.legacy` that blocks commits in **every** worktree. If it happens, remove that file after confirming it is byte-identical to `commit-msg`. |

Nothing here writes to the real `~/.kiro`. If a step tells you it did, stop.

---

## Step 0 — run the offline self-tests

These launch nothing. They are the reason the later steps are trustworthy.

```bash
cd fixtures/kiro-primitives/harness
bash ./self-test-bucket.sh
bash ./self-test-seed.sh
```

**Expect:** `PASS` from both. The first ends with `buckets reproduced: 19` (or
however many workspace buckets exist on this machine — the number is live, the
`mismatched: 0` is what matters). The second ends with `passed: 12 / failed: 0`.

**If `self-test-bucket.sh` reports any mismatch:** stop. The bucket derivation
no longer matches the engine's, so every seed would land in a directory the
engine never reads — and that failure is **silent**. Fix the derivation before
going on.

**If it reports `no buckets were examined`:** the enumeration found nothing.
That is a failure, not a pass — a green result over an empty set means nothing.

---

## Step 1 — bring up the scratch environment and seed a session

```bash
cd fixtures/kiro-primitives/harness
eval "$(./scratch-up.sh)"
./seed-session.sh
```

**Expect** four lines: `session_id=`, `session_dir=`, `bucket=`, `launch_cwd=`,
followed by the launch instructions.

Record the `session_id` — every later step needs it. Set it once:

```bash
sid='<the session_id from above>'
```

**Sanity-check the seed before launching** (still no Kiro):

```bash
jq . "$KIRO_FIXTURE_HOME/.kiro/sessions/$(printf '%s' "$KIRO_FIXTURE_WORKSPACE" | sha256sum | cut -c1-16)/$sid/session.json"
```

**Expect** exactly nine keys, with `"workflowsEnabled": true` at the **top
level**. If it is nested under anything, the flag will read as absent and floor
to `false`, and nothing will report a problem.

---

## Step 2 — launch, resuming by id, from exactly the seeded cwd

```bash
(cd "$KIRO_FIXTURE_WORKSPACE" && env HOME="$KIRO_FIXTURE_HOME" \
   kiro-cli --v3 --tui --resume-id "$sid")
```

Three things about this command are load-bearing:

- **`--resume-id`, not `--resume` or `--resume-picker`.** `--resume` is
  position-dependent and the picker is interactive. Note `--list` is an **alias
  for the interactive picker**, not for `--list-sessions` — typing it expecting
  a listing drops you into a TUI.
- **The cwd must be exactly `$KIRO_FIXTURE_WORKSPACE`.** The session bucket is
  derived from the _request's_ cwd, so launching from anywhere else looks in a
  different bucket, finds nothing, and silently creates a fresh session with
  workflows **off**.
- **`HOME` is the isolation lever.** Not `KIRO_HOME`, which means a different
  thing one layer up and would leave the engine reading the real home.

**Expect** a v3 TUI. If the workspace is untrusted, accept the trust prompt and
note that you did — trust changes whether workspace agent profiles load at all.

---

## Step 3 — the typed positive control (do this first, in-session)

Type exactly:

```text
/workflow-run
```

**Expect exactly:** `/workflow-run is not yet supported in KAS mode`

That message is **the confirmation that the seed worked.** The four
`/workflow-*` commands are advertised by the engine only when the session's
workflow flag resolved true, but the shipped client has no handler for them, so
the text falls through and returns that string. It proves the gate opened
without needing the model to cooperate.

**If the command is not offered / not recognized at all:** the flag did not
take. Go to step 4 for the diagnosis — do not retry the launch blindly.

**Do not** expect this command to actually run a workflow. It cannot. It is a
control, not a path.

---

## Step 4 — confirm the seed was read (run this every time)

Leave the session running, or exit — either is fine. In another shell:

```bash
cd fixtures/kiro-primitives/harness
./assert-seed-took.sh "$sid"
```

**Expect** `PASS  the seed was loaded and the workflow gate saw it`.

This step is not optional and not a formality. Loading an unknown session id
**does not error** — the engine hydrates a fresh session with default flags and
persists it over the path. So "workflows just didn't turn on" and "the enable
path does not work" look identical from inside the TUI. The script separates
them:

| What it says                           | What happened                                                                                                                                                                        |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `no engine log under the scratch HOME` | The engine never started with this `HOME`. The redirect did not take.                                                                                                                |
| `session root is '<other>'`            | The redirect did not reach the engine. If it names the real home, `os.homedir()` resolved elsewhere.                                                                                 |
| `create_uncreated is present`          | **The seed was not found.** Almost always a bucket mismatch — re-check the launch cwd against the bucket.                                                                            |
| `no 'Loaded session' line`             | The engine never loaded this id. Check the id you passed against the seeded one.                                                                                                     |
| `bucket holds N session directories`   | A rival session was created beside the seed — the on-disk footprint of the same silent failure.                                                                                      |
| `workflowsEnabled is 'false'`          | The seed was present but not honored. Re-check that the flag is at the **top level** of the file.                                                                                    |
| `note  no debug lines in the log`      | Not a failure. `KIRO_LOG_LEVEL` did not reach the engine, so adapter and hook-suppression diagnostics are unavailable this run. Fall back to info-level lines and transcript events. |

---

## Step 5 — confirm the tools registered

In the session, ask for the available tools (or open the tool list in the TUI)
and look for the workflow tool family. Registration is **all-or-nothing**:
either the whole family is present or none of it is.

**If step 3 passed but no tools are present:** that is a real finding, not a
mistake — it would mean the command advertisement and the tool registration have
separate gates. Record it.

---

## Step 6 — start the bundled recipe

There is **no deterministic typed way** to start a workflow in the shipped CLI.
The `/workflow-*` commands are inert (step 3), and the one command that _is_
wired end-to-end is gated on a different setting that seeding does not unlock.
So the start is a **tool call the model must choose to make** from prose.

Ask, in one turn, naming the recipe and both inputs verbatim. Something like:

```text
Use the run_workflow tool to start the workflow at bundled://ralph.
Pass inputs.goal = "<a small, concrete, verifiable goal>" and
inputs.prd_path = "<a relative path inside this workspace>".
Both values must be strings.
```

**Expect** a tool result containing: `started successfully. Status: running.`

**Record the exact prompt text you used in the fixture** so the run is
replayable. Expect to need a few phrasings before one lands reliably — that is a
property of the surface, not a mistake.

Three failure modes worth telling apart:

- `no bundled recipe named '<x>'` — the URI is wrong. It is an exact,
  case-sensitive registry match: no trailing slash, no `.workflow.json`, no case
  variation.
- A validation error — the definition or inputs were rejected before anything
  ran.
- An execution error — it started and failed.

**Pass both inputs explicitly, as strings.** `inputs` is a string-valued map, so
a numeric value fails the schema parse. And starting with no inputs is worse
than it looks: a template reference with no value supplied only **warns** and is
passed through as literal text, so the recipe's file check can never satisfy,
and its shipped exhaustion policy parks the run in a **paused** state that
cannot be retried and grants no further iterations on resume.

Note the bundled recipe is a **sequential** drain — one step per iteration, no
parallel node. It validates the loop primitive and durable mid-run progress. It
is **not** the concurrency test; that is the custom drain definition.

---

## Step 7 — capture, then tear down

Before teardown, capture what the run produced. Workflow run state lives beside
session storage:

```bash
find "$KIRO_FIXTURE_HOME/.kiro/sessions" -path '*/workflows/*' -maxdepth 4 | head -20
```

**No workflow had ever run on the capture machine**, so this directory being
created at all is a clean, unambiguous before/after signal.

Then:

```bash
cd fixtures/kiro-primitives/harness
./scratch-down.sh --keep-logs
```

`--keep-logs` preserves the engine logs outside the scratch root, which is what
you want if anything was surprising. The teardown refuses any target that is not
under the scratch root.

---

## What this session settles

1. Whether the seed-and-resume enable path works at all (steps 3–5).
2. Whether a fresh session lacks the surface — run one **without** seeding as
   the negative control, proving the seed is what did it.
3. Whether the bundled recipe runs, and what the start actually looks like from
   the operator's side (step 6).

What it does **not** settle: independent refill across parallel branches. That
needs the custom drain definition and its own sitting.
