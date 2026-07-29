# Research: front-loading a skill's bootstrap reads into turn 0

> Status: **RESEARCH / DESIGN — not planned, not implemented.** Picked up
> 2026-07-18 on branch `refactor/ai-factory-architecture`. Question from the
> operator: when a skill fires, can we hook it / auto-switch to a subagent /
> pre-inject its multi-turn bootstrap reads so the content is already in context
> on the first turn instead of burning 3–4 tool-call turns. Concretely targets
> the `living-workflow` skill's resume path. Claude-first; Kiro parity is a
> noted seam, not solved here.
>
> No code was changed. Two mechanism claims below are flagged **UNVERIFIED** —
> confirm against a live payload before wiring anything.

## Problem

`living-workflow`'s resume bootstrap is a **pointer-chase**, not a fixed file
set: `state.json.current_position` → the relevant slice → its phase brief →
phase-summaries. Because each read names the next, they can't be batched in
parallel, so the model spends 3–4 sequential tool-call turns just getting to the
point where it can act.

Goal: collapse those bootstrap reads to **zero** tool-call turns — the resolved
working set already in context when the model takes its first turn.

## The two direct questions

### Q1. Auto-switch to a named subagent when a skill runs?

**Yes as a capability, but via skill frontmatter — not a hook — and it is the
wrong tool for `living-workflow`.**

- Claude Code supports running a skill's body inside a forked subagent (skill
  frontmatter, keys resembling `context: fork` + `agent: <name>`; **exact key
  names UNVERIFIED** — confirm in the skills docs). The subagent runs the whole
  skill and returns only its final result to the main thread.
- Hooks **cannot** auto-dispatch to a subagent.
- This is right for a self-contained, read-heavy skill whose only job is "read a
  pile of files, hand back a summary." It is **wrong for `living-workflow`**,
  whose entire purpose is to drive the _main_ conversation across turns. Fork it
  and the plan-driving context dies the moment the subagent returns.

### Q2. Hook when a specific skill runs?

**Yes.** A skill invocation is a call to the `Skill` tool, so a `PreToolUse` /
`PostToolUse` hook with `matcher: "^Skill$"` fires on it, and you branch on the
skill name inside `tool_input`. There is **no** dedicated `SkillStart` /
`PreSkill` event — everything rides the generic tool hooks.

- **UNVERIFIED — field name.** A research agent claimed the branch key is
  `tool_input.skill_name`. But this session's `Skill` tool takes a parameter
  named `skill`, so the payload key is almost certainly `.tool_input.skill`. A
  hook keyed on the wrong name silently never matches. Confirm by dumping one
  real payload before wiring:
  ```bash
  # throwaway PostToolUse hook on Skill:
  jq '.' > /tmp/skill-payload.json <<<"$(cat)"
  ```
- `PostToolUse` hooks can return injected context (`additionalContext`) that
  lands on the next turn — this repo already studied the PostToolUse-JSON-on-
  stdout contract in `docs/plans/prek-posttooluse-hook-feedback-channel.md`.
  That prior hook was disabled for a **file-mutation** race (prek rewriting
  files mid-turn → stale Edit snapshots); a **read-only** context-injecting hook
  has none of that exposure.

## The better primitive for a chain: inline dynamic context

Docs: `code.claude.com/docs/en/skills#inject-dynamic-context`. SKILL.md can
contain `` !`command` `` which runs at **skill-load time** (before turn 1) and
injects the command's stdout into the skill's rendered content.

This beats a hook for the chained-read case: a single script can walk the whole
pointer-chase server-side and dump the resolved working set. No tool-call turns,
no `additionalContext` plumbing.

- **UNVERIFIED / correction.** `` !`…` `` is markdown-file syntax (skills /
  slash commands). It does **not** execute inside a hook bash script — in a hook
  you run commands normally. Do not conflate the two (an earlier research reply
  did).
- Put the traversal in a real script and invoke it with one line, e.g.
  `` !`bash <skill-dir>/bin/resume-bootstrap.sh` `` — keeps SKILL.md clean and
  makes the logic testable (mirror the `checks/validate-at-stop.nix` harness).

## The write question (turn accounting)

Concern raised: "do you still need to write before read — not really saving a
turn?" Answered against the actual protocol:

Resume is **read-first**, so the injection cleanly removes the read turns:

- WARM START (`references/living-plan-bootstrap.md` step 2, ~line 722): _read_
  `state.json` → derive position → load working set. Pure reads.
- The only early write is conditional and **not in the read chain**: "first
  commit any orphaned prior-session status-flip" — a git commit of an
  already-recorded flip, skipped entirely in a resident-commits repo. It gates
  no read.
- The real writes — `INTENT before acting → PROGRESS → DONE` (line 518) and
  session-close `mutate state.json` (line 214) — are all **write-before-_act_**,
  not write-before-_read_. They land on turns spent doing work regardless.

```
Before:  turn1 read A · turn2 read B · turn3 read C · turn4 act(+first WAL write)
After:   turn1 act(+first WAL write)   ← A/B/C already injected
```

The read turns are saved outright. The first WAL-INTENT write does not become
more expensive because reads went free — it was always riding a work turn. There
is no "write before read" that cancels the savings, because at resume nothing
must be written before the bootstrap reads. (The savings would only be defeated
by a `read → write → read` bootstrap, which this protocol does not have.)

### Two real caveats

1. **The injected script MUST be strictly read-only** (cat / jq, zero mutation).
   It runs _outside_ the turn loop, before the model has acted and before any
   HITL gate. If it wrote — a WAL INTENT, a state flip — it would mutate state
   before anything was decided, breaking the `INTENT before acting` discipline
   (line 518) and firing an ungated side effect. Read / compute only.
2. **The snapshot is frozen at load time.** After turn 1, writes the session
   makes are not reflected in the injected block — but that is a non-issue, you
   don't re-read your own writes (the model/harness tracks them). It only bites
   if an **external** writer mutates state mid-session; ordinary state is
   _clone-scoped and shared across worktrees_ (SKILL.md line 61), so a sibling
   worktree could. That is a rare reconcile resolved with one fresh tool-call
   read — not a bootstrap cost.

### Bonus the script buys

`state.json` is durable state; the WAL journal holds intent/progress/done not
yet folded in. A naive read gives a pre-fold view. The bootstrap script can
**fold the WAL server-side** (jq over the journal) and inject the _reconciled_
`current_position` + register — so the injected content is more correct than a
raw read, while still writing nothing.

## Recommended approach — layered, cheapest first

**Layer 1 — parallelize the non-chained reads (free, portable to Kiro).** Where
the resume/create/groom steps load _independent_ files (e.g. the two static
protocol docs), instruct reading them in a single message. Does not solve the
pointer-chase, but trims easy turns and is Kiro-safe. SKILL.md today prescribes
numbered sequential steps with no batching instruction.

**Layer 2 — pre-bundle the static protocol in `mkSkill.nix` (portable).** The
run-time static set is exactly `references/living-plan-bootstrap.md` +
`references/state.schema.json` (groom additionally
`living-workflow-backlog.md`). Add one build step to the `runCommand` in
`packages/living-workflow/lib/mkSkill.nix` (~lines 25–29, alongside the existing
`@XDG_STATE_BASE@` sed) that concatenates them into
`references/bootstrap-bundle.md`, and point SKILL.md at the bundle. One read
instead of two/three; produced **inside** the derivation (never mutate the store
copy). Portable to Kiro.

**Layer 3 — inline dynamic-context injection for turn-0 (Claude-only).** Add
`` !`bash …/resume-bootstrap.sh` `` to the resume section of SKILL.md. The
script: compute `<state-root>` → read `state.json` + WAL → fold WAL → resolve
`current_position` through the chain (slice + phase brief + phase-summaries) →
emit the reconciled working set. Strictly read-only. Model starts at step 4
("act by position class") on turn 1.

Do Layer 1 + Layer 2 regardless (portable, cheap). Reach for Layer 3 only if
turn-1-vs-turn-0 materially improves the resume UX — it buys one turn at the
cost of Claude-only machinery and the entry-point wrinkle below.

## Nix wiring notes (from repo recon)

- **Skill generator:** `packages/living-workflow/lib/mkSkill.nix` — `runCommand`
  that `cp -R`s `references/` and seds `@XDG_STATE_BASE@` into SKILL.md.
  `stateBase` comes from the HM module
  (`packages/living-workflow/modules/homeManager/default.nix:35-38`,
  `${config.xdg.stateHome}/living-workflows`) and the devenv module
  (`packages/living-workflow/modules/devenv/default.nix:31-34`). Natural home
  for Layer 2's concat and for a per-target SKILL.md render (Layer 3).
- **A `Skill` PostToolUse hook (if pursued instead of / with `` !`command` ``)**
  wires cleanly in `devenv.nix`'s `claude.code.hooks` block (~lines 168–185), as
  a sibling to `validate-at-stop`. The devenv `hookSubmodule` supports
  `hookType = "PostToolUse"` + a regex `matcher` (precedent: upstream
  `git-hooks-run` uses `matcher = "^(Edit|MultiEdit|Write)$"`). Reuse the
  `lib/validate-at-stop.{nix,sh}` authoring pattern (a `writeShellApplication`
  with absolute-path `runtimeInputs`) and the `checks/validate-at-stop.nix` test
  template.
- **Correction to an earlier premise:** there is **no** nix-managed
  `SessionStart` hook in this repo's Claude settings. The global
  `~/.claude/settings.json` has only a `PreToolUse` Bash hook
  (`claude-gh-to-mcp-hook`, from the separate `nixos-config`). The SessionStart
  context seen in sessions comes from plugins (remember, superpowers), not from
  a hook authored here.

## Open decisions / seams

1. **Entry-point disambiguation.** A `Skill`-hook (or a single injection line)
   can't easily tell resume vs create vs groom unless the skill `args` carry it.
   `` !`command` `` in the _resume section_ of SKILL.md sidesteps this — it only
   renders on the resume path — so inline injection is cleaner than a hook here.
2. **Kiro portability.** `` !`command` `` is Claude skill syntax; Kiro renders
   it literally / ignores it. Clean fix: per-target SKILL.md rendering in
   `mkSkill.nix` (Claude gets the injection line; Kiro keeps the plain numbered
   read steps). Deferred — Claude-first for now.
3. **Verify before wiring:** (a) the `tool_input` skill key name; (b) whether
   `` !`command` `` is supported in _skills_ (docs section title implies yes;
   the operator linked it) and its load-time timeout / size behavior; (c) exact
   subagent frontmatter keys if Q1 is ever revisited.

## Suggested next step

Draft `resume-bootstrap.sh` (chain-chase + WAL fold, read-only) and the SKILL.md
`` !`command` `` line, plus the Layer 2 `mkSkill.nix` bundle step, for review
before anything lands.
