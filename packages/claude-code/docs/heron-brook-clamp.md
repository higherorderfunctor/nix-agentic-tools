## heron_brook Delegation Clamp — the escape clause

> **Last verified:** 2026-11-06 — Claude Code 2.1.319 still ships the clamp with
> its CLAUDE.md-or-skill escape clause; the mitigation lives in
> delegate-routing’s per-turn reminder, and nothing watches upstream for its
> removal.
>
> **Settled — do not relitigate.** Full lineage:
> `git show 3510a5db:packages/claude-code/docs/heron-brook-clamp.md`.
>
> - **A per-update version tripwire was TRIED and REJECTED.** It compared the
>   pinned claude-code version against a recorded `verifiedClaudeVersion`, so it
>   went red on every release and was right on none of them.
> - **A ~90-day dated review was TRIED and REJECTED.** A `ci.yml` step on the
>   claude-code update PR failed past a `reviewBy` date. Its only job was to
>   find out when the grant could be dropped, and a grant left behind after
>   upstream removes the clamp does no harm, so the calendar only turned bot PRs
>   red.

Claude Code injects a system-prompt section — internally `heron_brook` —
instructing the model not to call the Agent tool and not to use workflows or
deep research "unless the user, a CLAUDE.md file, or a skill asks for it". It is
gated on a model capability rather than user configuration: an Opus 5 / Sonnet 5
control pair found it present on Opus 5 and absent on Sonnet 5. No setting or
flag disables it, and it never appears in the transcript, so a session with
delegation suppressed looks identical to a normal one.

### Why user-voiced context satisfies it

delegate-routing’s per-turn reminder supplies the mitigation. Its
`UserPromptSubmit` context supplies the request the clamp’s own escape clause
asks for. Nothing is patched. The clamp also negates
`ai.claude.ultracodeOnLaunch`, so on Opus 5 that option depends on the
reminder’s grant.

`UserPromptSubmit`’s `additionalContext` lands inside the human turn.
`SessionStart` context carries a `SessionStart hook additional context:` prefix
and reads as system-level. A live session recognized the hook channel while
accepting first-person content as a standing instruction from the user: the
mechanism relies on the user’s voice, not concealment.

Re-derive these properties before rewording the permission grant:

1. It satisfies "unless the user … asks for it" rather than contradicting the
   system instruction.
2. It is affirmative: a positive request avoids asking the model to ignore an
   instruction it cannot point at.
3. It is first-person: the user’s voice carries the request even when the hook
   channel is visible.
4. It grants permission rather than mandating delegation; the agent retains
   judgment about whether delegation fits the task.

### Checking upstream by hand

Nothing re-checks the clamp on a claude-code bump. To see whether a release
still ships it, download the pinned binary from `sources.json` and grep it. The
positive control is not optional; a clean negative from an unverified grep on a
~300 MB binary proves nothing:

```bash
grep -ac 'NotebookEdit' "$B"              # control, must be >0
grep -ac 'or a skill asks for it' "$B"    # 0 => clause changed or fixed
grep -ac 'tengu_heron_brook' "$B"         # the gate
```

Presence is the signal, never the count: grep counts lines and the bundle is
minified, so counts drift with no behavior change. If upstream fixed it, drop
the permission grant from delegate-routing’s per-turn reminder. Upstream tracks
it in
[anthropics/claude-code#80988](https://github.com/anthropics/claude-code/issues/80988).
