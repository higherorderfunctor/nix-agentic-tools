# Runbook — Session B: subagent and hook mechanics

Mode **F**, operator-driven. Read `RUNBOOK-session-a.md`'s preconditions first —
they apply here unchanged, including that every command block is bash and that
`XDG_DATA_HOME` must stay real.

This session settles seven things. None of them needs the workflow flag, so **no
seeded session is required** — a fresh session under the scratch `HOME` is
enough.

## The rule that shapes every step below

**Verify structure from transcripts, never from the display.** The interactive
view collapses a completed dispatch node into a summary counting only its
**direct** children, so a grandchild appears to have been spawned by the root.
That is not a rendering quirk you can squint past — it produces exactly the
wrong answer to the only question this session asks. Every structural claim here
is read back with `verify.py reconstruct`.

A second, subtler one found while building that reconstruction:
`parentExecutionId` is **not** the nesting edge. Using it flattens the forest to
depth 1 where the correct edge reaches 2. `verify.py`'s C5 check is the control
for precisely this, so let it do the walking.

---

## Step 0 — materialize the probes BEFORE launching

This ordering is not stylistic. Writes into `.kiro/agents/` and `.kiro/hooks/`
are policy **ask** — never auto-allowed — and `~/.kiro/settings/` is a hard
deny. An agent that tries to create its own probe files mid-session hangs on an
approval prompt.

```bash
cd fixtures/kiro-primitives
eval "$(./harness/scratch-up.sh)"

# Profiles go to the scratch HOME, not the workspace: home profiles load
# unconditionally, workspace profiles only once the workspace is trusted, and a
# fresh scratch directory is untrusted until you accept it.
mkdir -p "$KIRO_FIXTURE_HOME/.kiro/agents" "$KIRO_FIXTURE_HOME/.kiro/hooks"
cp agents/profiles/*.md agents/profiles/*.json "$KIRO_FIXTURE_HOME/.kiro/agents/"

# Hooks must be REAL REGULAR FILES and the scan is FLAT. cp, never ln -s.
cp hooks/*.json "$KIRO_FIXTURE_HOME/.kiro/hooks/"
mkdir -p "$KIRO_FIXTURE_HOME/.kiro/hooks-bin"
cp hooks/bin/*.sh "$KIRO_FIXTURE_HOME/.kiro/hooks-bin/"
chmod +x "$KIRO_FIXTURE_HOME/.kiro/hooks-bin/"*.sh
```

Then refuse to continue unless the linter is happy:

```bash
./scripts/lint-probes.sh "$KIRO_FIXTURE_HOME/.kiro/agents" "$KIRO_FIXTURE_HOME/.kiro/hooks"
```

**Expect** `PASS`. Every rule it enforces exists because the engine's failure
for that mistake is **quiet** — a dropped profile, a skipped hook, a hook that
never fires. If it refuses, fix the file; do not proceed and interpret the
silence.

**Confirm the pair is a one-line diff** — that is the entire experimental
control for fixture 9:

```bash
diff agents/profiles/probe-hook-gate-default.md agents/profiles/probe-hook-gate-custom.md
```

**Expect exactly one changed line**, `dispatchKind: sub-agent` versus
`dispatchKind: custom-agent`. The `sub-agent` value is written explicitly rather
than omitted precisely so this diff is one line without changing behavior.

---

## Step 1 — launch

```bash
(cd "$KIRO_FIXTURE_WORKSPACE" && env HOME="$KIRO_FIXTURE_HOME" \
   kiro-cli --v3 --tui)
```

Accept the workspace trust prompt and **note that you did**. Trust decides
whether workspace agent profiles load and whether hooks _execute_ — and the two
are gated differently, which is the diagnostic in step 4.

**First, confirm the profiles loaded.** In the engine log:

```bash
grep -E 'Registered (user|workspace) profile' "$(ls -1d "$KIRO_FIXTURE_HOME"/.kiro/logs/*/kiro.log | tail -1)"
```

**Expect one line per profile file you copied.** A missing line is the trap, not
an error to search for. In particular a profile whose id collides with a builtin
mode (`vibe`, `spec`, `quick-spec`, `bug-fix`, `plan`, `autonomous`) **loads and
is then filtered out of the registry** — it looks loaded but cannot be
addressed. All shipped probes are prefixed `probe-` to stay clear of that.

---

## Step 2 — fixture 7: nesting, proven by nonce

Dispatch `probe-nonce-parent`. It mints a token, passes it to
`probe-nonce-child`, and reports only whether the echo matched — the token
itself never reaches root.

**Expect** a final line `NONCE-MATCH: yes`.

That the root never sees the token is the point: a match cannot be explained by
root having synthesized the child's reply. Then read the real shape:

```bash
python3 verify.py reconstruct --sessions-root "$KIRO_FIXTURE_HOME/.kiro/sessions"
```

**Expect** a tree reaching **depth 2**, and `C5` passing — which is the
assertion that the naive edge would have flattened it to 1.

**The negative control, in the same session:** dispatch a **default-role**
subagent and ask it to list its tools. **Expect the delegation tool to be
ABSENT.** That is the entire real content of "subagents cannot recurse": it is a
fact about what the default role is granted, not a prohibition in the engine.
The probe parent can nest only because its profile explicitly grants
`invoke_sub_agent`.

---

## Step 3 — fixture 8: the depth limit

Drive nesting to depth 6.

**Expect** the engine's own depth-exceeded error naming the limit of 5. A silent
stop at depth 5, or a success at 6, is a finding — record which.

---

## Step 4 — fixtures 9–11: the hook trigger split

Dispatch each half of the pair and give each a unique marker in its tool call.

| Trigger family                             | Expected in a dispatched sub-execution          |
| ------------------------------------------ | ----------------------------------------------- |
| `PreToolUse`, `PostToolUse`, `PostFile*`   | fires **unconditionally**, both halves          |
| `SessionStart`, `UserPromptSubmit`, `Stop` | fires **only** for `dispatchKind: custom-agent` |

Read firing from the transcript, not the log — hook _firing_ has no info-level
line at all:

```bash
grep -o '"hookId":"[^"]*"' <transcripts> | sort | uniq -c
```

`hookId` is the hook's **absolute file path** plus `#hook-<index>`, and it is
the **only** reliable way to tell which root a hook came from. Do **not** use
the payload's `cwd` for that — it is pinned to the first workspace root for
hooks from _every_ root, including the home directory.

**If a probe is in the load count but never fires:** the workspace is untrusted.
Hook _loading_ is not trust-gated; hook _execution_ is. That suppression is
logged at **debug** only, so if `KIRO_LOG_LEVEL` did not reach the engine you
will see nothing at all — check `assert-seed-took.sh`'s note from Session A, or
just re-accept trust.

**If a probe is absent from the load count:** it is a symlink or a schema
failure, not a trust problem. Different cause, different fix.

**Fixture 10, from the same log:** `UserPromptSubmit` carries an empty `prompt`;
`PreToolUse` carries real `tool_input`; `PreToolUse` exit-0 stdout is
**discarded** while exit 2 blocks; `PostToolUse` never injects.

**Fixture 11:** a `Stop` hook exiting **1** injects its text and restarts the
graph — the loop primitive. Note the productive exit code here is 1, not 2, and
that `SessionStart` / `UserPromptSubmit` bypass the decision function entirely
and inject on **any** exit code.

**One correction to carry:** there is no per-worker hooks directory. Per-profile
hook scoping is the inline `hooks:` array **inside a profile**, and it is
registered only for the **session's** agent — never for a dispatched subagent.
If you were expecting to give drainers their own hooks directory, that does not
exist.

---

## Step 5 — fixture 12: load roots and the symlink trap

The 4-cell matrix collapses to **two** distinct mechanisms, because both roots
use the same loader and the same filter. Both _real-file_ cells are already
empirically proven on this machine, so only the **symlink** cells are new:

```bash
ln -s "$PWD/hooks/probe-quiet-post-tool-use.json" \
      "$KIRO_FIXTURE_HOME/.kiro/hooks/probe-symlinked.json"
```

**Expect** the symlinked file to be **absent from the load count** — no warning,
no log line, no error. That silence is the finding.

**One extra cell worth running, because it would change how this repo ships
hooks:** a symlinked hooks **directory** (pointing at a directory of real files)
is predicted to load, since the existence check follows symlinks and a directory
read lists the target's entries typed by their own kind.

```bash
mv "$KIRO_FIXTURE_HOME/.kiro/hooks" "$KIRO_FIXTURE_HOME/.kiro/hooks-real"
ln -s "$KIRO_FIXTURE_HOME/.kiro/hooks-real" "$KIRO_FIXTURE_HOME/.kiro/hooks"
```

Restart and read the load count. **A non-zero count settles it affirmatively**
and unlocks a fully declarative delivery path for the home-manager module —
worth more than the fixture itself.

---

## Step 6 — fixture 13: agent-definition reload

Edit a loaded profile mid-session, then resume.

**Expect the change NOT to take effect** — a restart is required. Confirm by
re-reading the `Registered … profile` lines after restart rather than by
behavior, which is easy to misread.

---

## Step 7 — capture and tear down

```bash
python3 verify.py reconstruct --sessions-root "$KIRO_FIXTURE_HOME/.kiro/sessions" > /tmp/session-b-tree.txt
./harness/scratch-down.sh --keep-logs
```

Record, for every count you report, **its denominator** — and stamp it, because
the transcript corpus is live and moves while you measure it.
