# stacked-workflows scope fix — root cause + architectural note

> **Status:** bug fix; proceeding autonomously. Journal will be
> updated inline if implementation reveals anything the plan didn't
> anticipate.
>
> **Bug:** `~/.claude/skills/sws-*` appears on the user's personal
> Claude scope. Intent was devenv-only (project scope) so sws-prefixed
> skills don't collide with the user's own home-scope `stack-*` skills.

## Root cause

**Load-bearing mistake: shared-option semantics misunderstood.**

`lib/ai/sharedOptions.nix` declares `ai.skills` / `ai.instructions` /
etc. It's imported by both `hmTransform.nix` and `devenvTransform.nix`.
The natural-language description "shared options" suggests values set
in one place flow to both backends. This is wrong:

- HM and devenv run **separate** `evalModules` invocations with
  independent config trees.
- Importing `sharedOptions.nix` into each only makes the **declaration**
  shared — the _values_ set in module config are per-evaluation.
- A value set in the HM-imported stacked-workflows module is visible
  only to HM's eval. Devenv's eval has a separate `config.ai.skills`
  that doesn't see HM's contributions.

The stacked-workflows devenv module comment says:

> "Skills and instructions are contributed by the HM module via the
> shared option pools; the devenv side of each CLI reads from those
> same pools."

This is the incorrect belief that drove the current structure. HM
contributes; devenv reads nothing; result: HM emits the skills
(leaking to personal scope) and devenv emits nothing (latent bug —
nobody's devenv has sws skills today even with
`stacked-workflows.enable = true`).

## Contributing factors

1. **Port-preserved leak from legacy.** Commit d088869 (A6,
   2026-04-09) absorbed the legacy stacked-workflows HM module into
   the content package verbatim — the original scope assumption came
   along. No audit happened at port time.
2. **Devenv test gap.** All seven sws module-eval tests run `evalHm`
   only. A single `evalDevenv` assertion on sws skill presence would
   have failed immediately and surfaced the scope asymmetry.
3. **"Approach B" (plain module) lacks factory guardrails.** The AI
   CLI factories (`mkAiApp`) have structural `hm = { config = …; }`
   vs `devenv = { config = …; }` blocks that force per-backend
   separation. stacked-workflows isn't an `mkAiApp` participant
   because it's a content package, not a CLI — so the author wrote
   a plain module and naturally picked one backend (HM) to house all
   contributions.

## Fix (grounded in root cause)

### A. Move contributions from HM → devenv

- **HM module** keeps only:
  - `stacked-workflows.enable` option
  - `stacked-workflows.gitPreset` option (genuinely HM-scoped — git
    config is personal)
  - gitPreset assertion
  - gitPreset config block
- **Devenv module** gains:
  - Same `enable` and `gitPreset` options (project-local `programs.git.settings`
    equivalent — but devenv doesn't have an equivalent to HM
    programs.git.settings; gitPreset remains HM-only. Need to verify
    during implementation whether devenv projects typically
    configure git locally and if so via what mechanism. See
    "Implementation pivot watchlist" below.)
  - `ai.skills.sws-*` contribution (fans to project-scope
    `.claude/skills/` etc.)
  - `ai.instructions` entry (fans per-ecosystem as before, but now
    at project scope)
  - `home.file` → `files.` for the reference docs write at
    `.claude/references/*.md`. Note `home.file` doesn't exist in
    devenv evaluation context — must use `files.*` with project-
    relative path.

### B. Flip existing tests to `evalDevenv`

Three existing tests (`module-sws-enable-sets-ai-skills`,
`module-sws-enable-sets-ai-instructions`,
`module-sws-reference-files-written`) currently run `evalHm` and will
START FAILING after the module move. Update them to `evalDevenv`
(and switch `home.file` assertions to `files.*`).

Keep the git-config tests on `evalHm` (correctly HM-scoped).

Keep `module-sws-default-disabled` on `evalHm` (option disable test
is valid in either context).

### C. Architectural note to prevent regression

Add a fragment documenting "shared-pool is per-eval, not cross-backend"
— somewhere agents and future authors will see it when writing a
plain module that contributes to `ai.skills` / `ai.instructions` /
etc. Candidate location:

- `dev/fragments/monorepo/*.md` (always-loaded) — TOO broad; this
  is a niche detail.
- `packages/stacked-workflows/fragments/dev/*.md` (scoped to
  `packages/stacked-workflows/**`) — appropriate, but only fires
  when editing that package. Won't catch authors of NEW plain
  modules.
- `lib/ai/fragments/dev/*.md` (scoped to `lib/ai/**`) — fires when
  editing sharedOptions.nix, ai-common, transforms. Authors
  investigating how shared options work would see it.

Best fit is `lib/ai/` scope. Fragment registration via
`dev/generate.nix` `devFragmentNames` — need to verify the
registration shape during implementation (the scoped fragment
generation pipeline has specific requirements per
`architecture-fragments.md`).

### D. Commit

Single commit: `fix(sws): scope skills/instructions/refs to devenv
(HM leaked to personal scope)`. Plus the doc fragment if it lands
clean; otherwise split commits.

## Implementation pivot watchlist

Items where reality might diverge from this plan — commit a journal
update BEFORE proceeding with an alternate approach:

1. **gitPreset in devenv.** If devenv has no `programs.git.settings`
   equivalent, leave gitPreset HM-only (current behavior). Don't
   invent a devenv git-config surface here — that's a separate
   design. If it turns out devenv DOES have a git-config mechanism
   we should use, update plan and proceed.
2. **References in devenv project path.** HM writes
   `home.file.".claude/references/foo.md".source = …`. Devenv
   equivalent is `files.".claude/references/foo.md".source = …` —
   but `files.*.source` can't recurse directories (documented in
   devenv files internals). Refs are flat .md files, no recursion
   needed, so a per-file entry pattern should work. Verify during
   implementation.
3. **Fragment registration location.** If `lib/ai/` doesn't have a
   scope registered in `dev/generate.nix` `packagePaths`, I may
   need to add the scope or pick a different fragment location.
   Update plan accordingly.
4. **Test harness assumptions.** `evalDevenv` doesn't include
   `programs.git.settings` or upstream HM claude-code options. The
   evalDevenv tests for devenv-moved contributions must only
   assert on devenv's `files.*` / shared `ai.skills` / etc. —
   not on `home.file` or `programs.*`.
5. **Breaking-change ripples.** If any currently-working invocation
   of the HM module depends on the sws contributions landing in HM
   (e.g., a consumer that expected `home.file.".claude/references/*"`),
   that breaks. User has already accepted breaking changes in this
   session, but noting for the commit message.

## Out of scope

- Removing `stacked-workflows.enable` at HM entirely (leaving only
  `.gitPreset` as a standalone option). Keeping `enable` intact for
  future HM-scope additions and to keep gitPreset gated.
- Redesigning `ai.skills` / `ai.instructions` pools to actually
  share across HM↔devenv evaluations. That would require a
  cross-evaluation mechanism (nix does not support this natively
  within flake output evaluation). Current per-eval semantics are
  correct; the MODULE's placement was wrong.

## Review checklist

- [ ] Root-cause explanation committed into the journal (this doc).
- [ ] HM module stripped of skills/instructions/references
      contributions; retains enable + gitPreset + assertions + git
      config.
- [ ] Devenv module gains skills/instructions/references at project
      scope via `files.*`.
- [ ] Existing `evalHm` tests for skills/instructions/references
      moved to `evalDevenv`.
- [ ] Git-preset tests stay on `evalHm`.
- [ ] Architectural note fragment added under `lib/ai/` scope (or
      flagged as deferred with reason).
- [ ] flake check green.
- [ ] Commit message explains the root cause and the move.
- [ ] Journal updated with any implementation pivots.
