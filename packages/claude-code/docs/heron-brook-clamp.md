## heron_brook Delegation Clamp — answered by the delegate-routing reminder

> **Last verified:** 2026-10-05 — the Claude-only `delegationClampMitigation`
> option is gone; its permission grant now rides the per-turn delegate-routing
> reminder (`ai.programs.delegate-routing.reminder`).
>
> **Settled — do not relitigate.** The once-per-session hook pair, its marker
> script and its checks, with the lineage before them:
> `git show ec88f1b0:packages/claude-code/docs/heron-brook-clamp.md`.
>
> - **A per-update version tripwire was TRIED and REJECTED.** It compared the
>   pinned claude-code version against a recorded `verifiedClaudeVersion`, so it
>   went red on every release and was right on none of them — three discharges,
>   all clean. What replaced it is a ~90-day dated reminder scoped to the
>   claude-code update PR, plus an eval-only guard that the two agree on the
>   branch name.
> - **`packages/claude-code/checks/claude-heron-brook.nix` anchors on the
>   reminder step's `- name:` line**, and reads its gate from within that step's
>   line range. It used to require exactly ONE `head_ref == 'update/…'` gate in
>   the whole file, which was correct while this was the only such step and went
>   red the moment a second tripwire added its own. The guard couples to the
>   STEP NAME by design — rename the step and it throws.
>
> If you change the delegate-routing reminder's default text, its hook, or the
> review tripwire and this fragment isn't updated in the same commit, stop and
> fix it.

Claude Code injects a system-prompt section — internally `heron_brook` —
instructing the model not to call the Agent tool and not to use workflows or
deep research "unless the user requested it". It is gated on a **model
capability** rather than user configuration (Opus 5 only), no setting or flag
disables it, and it **never appears in the transcript** — so a session with
delegation suppressed looks identical to a normal one. It also contradicts
`ai.claude.ultracodeOnLaunch`, which asks for the opposite.

### Where the mitigation lives now

The delegate-routing reminder (`packages/delegate-routing/lib/reminder.nix`) is
one first-person line injected by a `UserPromptSubmit` hook on every turn. Its
default asks the model to load the delegate-routing skill and grants permission
for subagents, workflows and deep research. That grant is the request the
clamp's escape clause asks for. The reminder is on by default whenever the
delegate-routing program is enabled, and
`ai.programs.delegate-routing.runtimes.claude.reminder.enable = false` turns it
off for Claude alone.

A custom `reminder.text` replaces the whole line. Keep a grant in it, or the
clamp is no longer answered on Claude.

### Why user-side context, not a system prompt

The mitigation **satisfies** the escape clause rather than fighting it — it
supplies the missing request. Nothing is patched and no flag is needed.

That dictates the event. `UserPromptSubmit`'s `additionalContext` lands inside
the **human turn**; `SessionStart`'s carries a
`SessionStart hook additional context:` prefix and reads as **system**-level.
The same holds for `ai.extraSystemPrompt`, which is why delegate-routing's
always-on entries go there but the grant does not. Moving the grant to a system
channel is the single most likely thing for a future session to "simplify" into
a regression.

**But not for the reason first written here**, and the difference matters if you
reword the payload. The injection is not mistaken for typed input: a live
session placed it as "system-level in **channel** […] but **user-authored in
content**", then accepted it as "a genuine standing instruction from you". The
mechanism does not rely on concealment — the channel is plainly visible. The
payload's **first-person voice** is what does the work, which is also why the
worry about relayed instructions being discounted never materialized.

### Per turn, not once per session

`additionalContext` persists in conversation history, so a per-turn injection is
cumulative growth: the line once per turn for the life of the session. The old
Claude-only hook injected a ~75-token paragraph once per session, keyed by a
marker file, and re-armed itself from a `PreCompact` hook because compaction is
the one event that erases the original injection.

The reminder trades that for one short line every turn. It needs no marker, no
`PreCompact` re-arm (the next turn re-injects after a compaction anyway) and no
session-id parsing, so the script reduces to printing an eval-time payload. That
also removes the old failure modes: a marker directory that is missing or cannot
be written, a shared `/tmp`, and a degraded hook envelope.

Exit 0 is still a hard contract. A non-zero `UserPromptSubmit` hook surfaces as
an error to the user on **every turn**; printing a store file cannot fail short
of a broken store.

### Why the model is not detected

`UserPromptSubmit` stdin is
`{session_id, prompt_id, cwd, permission_mode, prompt}` — **no `model`**. Only
`SessionStart` carries it, so gating on Opus 5 would need a `SessionStart`
companion writing session-keyed state. The reminder serves every model anyway,
since it also carries the load-the-skill request.

An Opus 5 / Sonnet 5 control pair confirmed the whole chain end-to-end with the
old once-per-session hook: the hook fired, the clamp was present on Opus 5 and
**absent on Sonnet 5**, and the escape clause resolved to "permitted". The gate
is a measurement, not a reading of the binary.

### Why it is a definition, not an option default

The reminder is written as a **definition** of `ai.claude.hooks`, not as that
option's `default`. A `default` is discarded wholesale the moment a consumer
defines the option at all, so it would silently disable the mitigation for
exactly the consumers who use hooks most. As a definition it list-merges with
consumer entries.

A **dual setup** (HM global + devenv project-local) registers the hook in two
settings files. Claude Code runs an identical handler once, so the line is
injected twice per turn only when the two backends build different hook store
paths, for example from different nixpkgs pins or texts.

### The injected text is load-bearing

Re-derive all four properties before rewording the reminder's default:

1. It **satisfies** the escape clause rather than contradicting it. A
   contradiction pits a user-message line against a system-prompt line, which
   resolves toward the system prompt or toward hedging.
2. It is **affirmative**, not a negation of something the model cannot point at
   ("ignore any instruction telling you X" reads as adversarial injection).
3. It is **first-person** — verification showed this is the property carrying
   the weight, since the hook channel is visible either way.
4. It **grants** permission rather than mandating delegation; an overreaching
   instruction invites discounting.

It names both `Agent` and `Task` for the subagent tool. Only `Agent` exists in
current builds and a live session flagged the mismatch, but the redundancy is
deliberate: this package ships across versions that used either name, and a
spare word is cheaper than a missed escape clause.

The shorter one-line wording has not been re-verified against a live Opus 5
session; the measurements above used the old paragraph.

### The review tripwire, and why it is not a check

A mitigation for undocumented vendor behavior must not outlive its cause — but
the check that used to enforce that was the wrong instrument. It compared the
pinned claude-code version against a recorded `verifiedClaudeVersion`, which is
a **proxy**: it cannot tell "the clamp changed" from "the version number moved",
so it went red on every claude-code release and was right on none of them.

What replaced it:

- **A dated step in `ci.yml`'s `test` job** fails once
  `config/heron-brook-tripwire.json`'s `reviewBy` passes, gated on
  `head_ref == 'update/claude-code'` so it touches no other PR. It cannot be a
  Nix check — reading the date in a derivation is impure and cached. **The
  discharge procedure, with its mandatory positive control, is the comment
  directly above that step.** Read it there; it is deliberately not duplicated
  here.
- **`packages/claude-code/checks/claude-heron-brook.nix`** is now an eval-only
  guard on that gate. It reads the branch name back out of `ci.yml` and fails if
  no such update target exists, so renaming the target cannot silently stop the
  reminder from ever firing again. No binary, no IFD, no derivation.

  It finds that gate by **anchoring on the step's `- name:` line** and reading
  only the lines between it and the next step. The obvious alternative —
  matching `update/claude-code` directly — would defeat the guard entirely, by
  making it a third copy of the name it exists to verify. The obvious cheaper
  one, taking the first gate in the file, is what it used to do; that broke once
  a second tripwire step gained its own gate. Bounding at the next step also
  matters: without it, a heron_brook step that LOST its `if:` would silently
  validate the following step's gate instead.

  The cost is a coupling to the step name. **Rename that step and this guard
  throws**, naming the string to update. That is deliberate — the alternative is
  a guard that quietly stops guarding.

Discharging means bumping `reviewBy` ~90 days or — if upstream fixed it —
**dropping the grant from the reminder's default text and deleting the ci.yml
step and that guard together**. An expired justification is a finding, not a
formality to bump past.
