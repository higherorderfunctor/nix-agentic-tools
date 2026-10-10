## heron_brook Delegation Clamp — the escape clause

> **Last verified:** 2026-10-08 — the mitigation lives in delegate-routing’s
> per-turn reminder; Claude retains the dated CI review and its guard.
>
> **Settled — do not relitigate.** Full lineage:
> `git show 3510a5db:packages/claude-code/docs/heron-brook-clamp.md`.
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

Claude Code injects a system-prompt section — internally `heron_brook` —
instructing the model not to call the Agent tool and not to use workflows or
deep research "unless the user requested it". It is gated on a model capability
rather than user configuration: an Opus 5 / Sonnet 5 control pair found it
present on Opus 5 and absent on Sonnet 5. No setting or flag disables it, and it
never appears in the transcript, so a session with delegation suppressed looks
identical to a normal one.

### Why user-voiced context satisfies it

The mitigation now lives in delegate-routing’s per-turn reminder. Its
`UserPromptSubmit` context supplies the request the clamp’s own escape clause
asks for. Nothing is patched.

`UserPromptSubmit`’s `additionalContext` lands inside the human turn.
`SessionStart` context carries a `SessionStart hook additional context:` prefix
and reads as system-level. A live session recognized the hook channel while
accepting first-person content as a standing instruction from the user: the
mechanism relies on the user’s voice, not concealment.

Re-derive these properties before rewording the permission grant:

1. It satisfies "unless the user requested it" rather than contradicting the
   system instruction.
2. It is affirmative: a positive request avoids asking the model to ignore an
   instruction it cannot point at.
3. It is first-person: the user’s voice carries the request even when the hook
   channel is visible.
4. It grants permission rather than mandating delegation; the agent retains
   judgment about whether delegation fits the task.

### The reminder, and why it is not a check

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

Discharging means verifying that delegate-routing’s per-turn reminder still
satisfies the clamp’s escape clause and bumping `reviewBy` ~90 days, or — if
upstream fixed it — **dropping the permission grant from delegate-routing’s
per-turn reminder and deleting the ci.yml step and that guard together**. An
expired justification is a finding, not a formality to bump past.
