## heron_brook Delegation Clamp — the opt-in mitigation

> **Last verified:** 2026-08-06 (commit pending — `delegationClamp.mitigate` is
> now **opt-in**, and the per-update version tripwire is gone. It compared the
> pinned claude-code version against a recorded `verifiedClaudeVersion`, so it
> went red on every release and was right on none of them; three discharges, all
> clean. What replaced it is a ~90-day dated reminder scoped to the claude-code
> update PR, plus an eval-only guard that the two agree on the branch name.
> Prior 2026-08-04: binary re-verification against 2.1.222. Prior 2026-07-29:
> confirmed end-to-end against two LIVE sessions on 2.1.220, which turned the
> model gate into a measurement.) If you change `ai.claude.delegationClamp`, the
> hook script, the injected text, or the reminder and this fragment isn't
> updated in the same commit, stop and fix it.

Claude Code injects a system-prompt section — internally `heron_brook` —
instructing the model not to call the Agent tool and not to use workflows or
deep research "unless the user requested it". It is gated on a **model
capability** rather than user configuration (Opus 5 only), no setting or flag
disables it, and it **never appears in the transcript** — so a session with
delegation suppressed looks identical to a normal one. It also contradicts
`ai.claude.ultracodeOnLaunch`, which asks for the opposite.

Set `ai.claude.delegationClamp.mitigate = true` to enable it.

### Why the mitigation is user-side context, not a patch

The clamp carries its own escape clause: _unless the user requested it_. The
mitigation **satisfies** that clause rather than fighting it — it supplies the
missing request. Nothing is patched and no flag is needed.

That dictates the event. `UserPromptSubmit`'s `additionalContext` lands inside
the **human turn**; `SessionStart`'s carries a
`SessionStart hook additional context:` prefix and reads as **system**-level.
`SessionStart` is the obvious cheaper choice and it is wrong — the single most
likely thing for a future session to "simplify" into a regression.

**But not for the reason first written here**, and the difference matters if you
reword the payload. The injection is not mistaken for typed input: a live
session placed it as "system-level in **channel** […] but **user-authored in
content**", then accepted it as "a genuine standing instruction from you". The
mechanism does not rely on concealment — the channel is plainly visible. The
payload's **first-person voice** is what does the work, which is also why the
worry about relayed instructions being discounted never materialized.

### Why once per session, not per turn

`additionalContext` persists in conversation history, so per-turn injection is
not fixed overhead that expires — it is cumulative growth, the same paragraph
once per turn for the life of the session.

The injector therefore fires once, keyed by a marker at
`${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/claude-delegation-clamp/<session_id>`, and
a `PreCompact` hook deletes it. Compaction is the one event that can erase the
original injection, so it is the one event that re-arms it.

Degraded inputs (malformed stdin, absent `session_id`) fall back to a **fixed**
key, never a varying one — a varying fallback would inject every turn and
restore exactly the cost this avoids. `checks/claude-delegation-clamp.nix` pins
that down.

### Exit 0 is a hard contract, so every filesystem call is best-effort

A non-zero `UserPromptSubmit` hook surfaces as an error to the user on **every
turn**. Under `set -e` that makes an unguarded `mkdir`, `touch`, `rm`, `cat`, or
`${VAR:?}` a latent per-turn error dialog, not a style nit. All are guarded.

Marker bookkeeping is best-effort and the injection happens regardless. The
realistic failure is a shared `/tmp` whose `claude-delegation-clamp/` is owned
by another user, reachable when neither `XDG_RUNTIME_DIR` nor `TMPDIR` is set. A
marker that cannot be written degrades toward **injecting**, never toward
silence: losing the cadence costs tokens, losing the injection costs the
mitigation itself. A missing payload file is the one case that lapses instead,
since there is then nothing to inject.

### Why the model is not detected

`UserPromptSubmit` stdin is
`{session_id, prompt_id, cwd, permission_mode, prompt}` — **no `model`**. Only
`SessionStart` carries it, so gating on Opus 5 would need a `SessionStart`
companion writing session-keyed state. At once-per-session cadence the waste on
other models is ~75 tokens once, cheaper than that state file and its staleness
modes. So there is no gate, deliberately.

An Opus 5 / Sonnet 5 control pair confirmed the whole chain end-to-end: the hook
fires, injects once, the clamp is present on Opus 5 and **absent on Sonnet 5**,
and the escape clause resolves to "permitted". The gate is a measurement, not a
reading of the binary. When re-verifying, trust the **marker** over the model's
self-report — one file named for the session id after the first prompt, none
after.

### Why it is a definition, not an option default

`mkClaude.nix` emits the hook pair as a **definition** of `ai.claude.hooks`, not
as that option's `default`. A `default` is discarded wholesale the moment a
consumer defines the option at all, so it would have silently disabled the
mitigation for exactly the consumers who use hooks most. As a definition it
list-merges with consumer entries;
`module-claude-delegation-clamp-composes-with-consumer-hook` pins that down.

Config parity is structural — both backends already lower `ai.claude.hooks` to
`settings.json`, so one write serves HM and devenv. Claude-only, no `ai.*`
fanout: `heron_brook` belongs to the Claude Code client's own system prompt,
which Kiro and Copilot never load.

A **dual setup** (HM global + devenv project-local) registers the hook twice.
Harmless by construction — the first `inject` writes the marker and the second
sees it, so exactly one injection happens however the scopes merge. Watch only
for the two scopes resolving different store paths once their flake pins
diverge; then whichever runs first supplies the payload.

### The injected text is load-bearing

`ai.claude.delegationClamp.text` is a first-person standing request. Re-derive
all four properties before rewording it:

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
- **`checks/claude-heron-brook.nix`** is now an eval-only guard on that gate. It
  reads the branch name back out of `ci.yml` and fails if no such update target
  exists, so renaming the target cannot silently stop the reminder from ever
  firing again. No binary, no IFD, no derivation.

Discharging means bumping `reviewBy` ~90 days or — if upstream fixed it —
**deleting the mitigation, the ci.yml step, and that guard together**. An
expired justification is a finding, not a formality to bump past.
