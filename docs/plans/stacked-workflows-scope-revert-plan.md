# Stacked-workflows scope revert + skill-packaging convergence

**Status:** S1 CODE-COMPLETE (2026-07-18), awaiting accept + commit. **DONE + verified (committed at 8a7d8a73):** Phase A (real-file refs + `passthru.skills`), B1 (modules emit unprefixed `stack-*` + router), D (module-eval tests). **DONE + verified (uncommitted, this session):** C (dev-repo `dev-` prefix wiring: sws `dev-stack-*` re-key + living-workflow `dev-living-workflow` via direct `mkSkill`; `enterTest` retargeted + on-disk ref-resolution guard added), E (5 source edits + regenerated committed copilot outputs), B2 (shared `lib/ai/mkSkillPackageModule.nix` + retrofit all 4 backend modules), F (guarded single-job: formatting + all 226 module/factory/fragments checks + options-doc all GREEN; pure-eval of Phase C exprs; `dev-living-workflow` skill build verified). **DEFERRED (documented deviations):** the standalone deref-reference helper (single-use in SWS overlay → premature abstraction, kept inline) and a NAMED re-key helper (realized as inline `lib.mapAttrs'`, a stdlib primitive — a wrapper for one call site would be the premature abstraction the DRY rule warns against). **DISCOVERED (need decision):** (1) options-doc prefix gap — `living-workflow.enable` missing from `hmPrefixes`, and neither sws nor LW `enable` in `devenvPrefixes` (PRE-EXISTING, not a retrofit regression; options-doc builds clean); (2) `dev/docs/concepts/{unified-ai-module,fragments}.md` + `devshell/docs-site/default.nix` still show the older `passthru.skillsDir` idiom (still VALID — skillsDir now = deref'd `skillsWithRefs` — not broken, just not the newer `skills` map). **NOT run locally (per OOM rule / scope):** full parallel `nix flake check` (→ CI after push) and `devenv test` (enterTest on-disk; correctness already covered by module-eval `sws-skill-references-resolve` + the devenv walker tests).
**Branch:** `refactor/ai-factory-architecture`
**Execution model:** supervisor-worker-verifier (subagent fan-out), NOT superpowers:executing-plans
**Deliverable of this session:** this plan (no code changes this session)

---

## 1. Goal

Revert the 2026-04 scope-fix decision that made stacked-workflows (SWS) stack
skills project-local only, and simplify:

1. HM activation installs the stack skills **user-global**, unprefixed (`stack-*`).
2. devenv module installs them **project-local**, unprefixed.
3. nix-agentic-tools keeps its own devenv activation so the skills are present
   in-repo even without a global install.
4. Drop the `sws-` prefix as the consumer/global default (it was a collision
   workaround that is no longer needed — no personal `stack-*` skills remain in
   `~/.claude/skills`).
5. Record the precedence/shadowing behaviour in a memory for future skill work.
6. Clean up stale content encountered along the way (dangling doc ref, stale dev
   fragment, `sws-` mentions on live surfaces).
7. **Converge** with the parallel living-workflow (LW) skill-packaging effort so
   both packages follow one convention.

Secondary, discovered during validation: **fix a latent bug** — the SWS skill
reference files are currently dangling symlinks and fail to load in every scope.

### Explicitly out of scope (do NOT touch, even if wired in)

- The **rules tooling / `ai.rules` conventions** the maintainer was experimenting
  with. Leave the existing rule wiring and any old conventions in place — this
  plan fixes SWS the right way and gets it working; it does not clean up the
  rules machinery. (This is why the Claude router double-emit below is accepted
  as-is rather than "fixed".)

---

## 2. Validated architecture (ground truth)

The AI factory is `mkAiApp` (record) + two projectors: `hmTransform` →
`home.file.*` (user-global) and `devenvTransform` → `files.*` (project). Shared
`ai.*` pools are **per-evalModules** (an HM value is invisible to the devenv
eval and vice-versa), so each backend must contribute in its own module.

### Skill install locations (key = install dir; both scopes = real dir + per-file symlinks; nested `references/` preserved)

| Ecosystem | HM-global                   | devenv-project           |
| --------- | --------------------------- | ------------------------ |
| Claude    | `~/.claude/skills/<name>/`  | `.claude/skills/<name>/` |
| Kiro      | `~/.kiro/skills/<name>/`    | `.kiro/skills/<name>/`   |
| Copilot   | `~/.copilot/skills/<name>/` | `.github/skills/<name>/` |

### Router (`ai.instructions`) locations — factory fans out automatically

| Ecosystem | HM-global                                                                                          | devenv-project                                    |
| --------- | -------------------------------------------------------------------------------------------------- | ------------------------------------------------- |
| Claude    | `~/.claude/CLAUDE.md` (+ `~/.claude/rules/<name>.md` if named)                                     | `.claude/CLAUDE.md` (+ `.claude/rules/<name>.md`) |
| Kiro      | `~/.kiro/steering/<name>.md` (inclusion frontmatter)                                               | `.kiro/steering/<name>.md`                        |
| Copilot   | `~/.config/github-copilot/copilot-instructions.md` + `.github/instructions/<name>.instructions.md` | project equivalents                               |

### Corrections to the earlier mental model

- **Claude router is `.claude/CLAUDE.md`, not `AGENTS.md`.** The
  `AGENTS.md` + `CLAUDE.md → @AGENTS.md` shape is _this repo's own dev pipeline_
  (`dev/generate.nix` + `devenv.nix:271-277`), NOT what `mkAiApp` emits to
  consumers.
- **Kiro router lives in `~/.kiro/steering/`, not `~/.kiro/instructions/`**
  (that path does not exist). `inclusion: always` is achievable (no `paths`);
  **`inclusion: manual` is NOT expressible via the factory today** (transformer
  emits only `always`|`fileMatch`).
- **There is no factory "references" concept.** References live inside the skill
  dir; the skill dir is the namespace (no shared dir, no name collision, no
  renaming needed).
- **Kiro reads global `~/.kiro/` for skills + steering** (upstream #9075 +
  operator-verified). Only _hooks_ are workspace-local. HM-global Kiro is valid.

### Consumer config surface (confirms "no new knobs")

- `ai.skills` is a bare `attrsOf path`; **no per-skill trigger knob exists** —
  trigger stays in `SKILL.md` frontmatter (`disable-model-invocation: false` =
  always available). We add nothing here.
- Router scope is per-entry via `paths` (`null` = always-on). Always-on router =
  contribute `ai.instructions` with no `paths`.
- Skill **key = install dir**, and per-scope re-keying already works (that is how
  `sws-` works today) — so a dev-repo prefix override needs no new option.

---

## 3. The latent bug (fix regardless)

Every SWS skill's pre-flight ("read `references/philosophy.md` before
proceeding") **fails today.** The per-skill refs are relative symlinks
(`skills/stack-fix/references/git-absorb.md -> ../../../references/git-absorb.md`).
`passthru.skillsDir = builtins.path ./skills` imports only the skills tree, so
`../../../references/` escapes the store path and **dangles**. Verified:
`cat .claude/skills/sws-stack-plan/references/philosophy.md` → _No such file_.

Reference fan-out (only what skills actually read): `git-branchless.md` ×5,
`philosophy.md` ×3, `git-absorb.md` ×1. The other three refs
(`git-revise.md`, `nix-workflow.md`, `recommended-config.md`) are referenced by
**zero** skills — keep them in source (per decision), do not bundle.

**Fix:** build self-contained skill dirs with **real** reference files. In the
content build, dereference the ref symlinks (`cp -RL` / `install`) from a source
layout where `./skills` and `./references` are siblings so the `../../../`
targets resolve, producing real files in each `skills/<name>/references/`. Point
`passthru.skillsDir` (and a new `passthru.skills` map) at that. Do **not** reuse
LW's `mkSkill.nix` as-is for SWS — its `cp -R` would copy the dangling symlinks
verbatim.

---

## 4. Convergence with living-workflow

LW touches **zero shared factory code** (only additive registrations in
`packages/default.nix` +1 line and `checks/module-eval.nix` append-only tests +
an `xdg.stateHome` stub). Collision risk ≈ zero.

| #   | Decision         | SWS (this plan)                                                  | LW (as built)                               | Canonical rule                                                                                                                               |
| --- | ---------------- | ---------------------------------------------------------------- | ------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Skill key prefix | unprefixed consumers/global; **prefix only in dev-repo devenv**  | bare `living-workflow` in both backends     | **Adopt SWS rule for both.** LW's devenv module should prefix (e.g. `lw-living-workflow`) — 1-line change, coordinate with parallel session. |
| 2   | References       | real files, deref'd at build (fix bug)                           | real files (already)                        | **Real files, both.** SWS build must `cp -RL`.                                                                                               |
| 3   | Scope            | HM global + devenv project, both first-class + keep in dev repo  | HM primary (global) + devenv parity         | Same wiring; both backends emit. Matches.                                                                                                    |
| 4   | Router           | routing-table via `ai.instructions` (n=6 sibling skills need it) | **no router** (single self-contained skill) | **Rule: router when a package ships >1 sibling skill needing disambiguation.** SWS yes, LW no — intentional, documented, not drift.          |
| 5   | Skill-list DRY   | single `passthru.skills` (readDir), consumers derive             | moot (n=1)                                  | SWS derives; LW n/a.                                                                                                                         |
| 6   | New knobs        | none                                                             | none                                        | Matches.                                                                                                                                     |

> **DECISION UPDATE (2026-07-18):** row 1 is now uniform — BOTH packages wire
> their devenv into this repo with a `dev-` prefix (LW is _not_ stable, so it
> needs shadow-free in-repo dev too). No cross-session coordination needed (LW
> landed). See §Phase C.

LW-specific, NOT applicable to SWS: Nix-**generated** SKILL.md (bakes
`config.xdg.stateHome` at eval; no overlay/`-content` derivation), XDG plan-state
relocation, changelog/versioning/migration, bootstrap/resume/groom entry points.

Because SWS feeds a **plain `./` path literal** (static skills) while LW feeds a
**generated store-path string**, any shared module helper must tolerate both
(`(isPath || isString) && readFileType == "directory"`).

### Coupling points that go stale when SWS changes (update in the shared-helper follow-up)

- `docs/plans/living-workflow-skill-packaging-design.md:61,66,81-84`
- `docs/plans/living-workflow-skill-packaging-plan.md:11-12,60-69,276`
- `packages/living-workflow/modules/homeManager/default.nix:7-12`
- `checks/module-eval.nix` LW comment ("INVERTING the sws choice", "Mirror the sws pattern")

---

## 5. Sequencing (relative to the parallel LW session)

> **STATUS: LW LANDED (2026-07-18).** LW shipped in 5 commits touching zero shared
> `lib/ai/` code (CI green); the tree is clean. This plan is unblocked and ready to
> execute S1 once the in-repo-devenv + prefix decision (§Phase C) is made.

1. **LW landed ✓** — non-conflicting (zero shared-lib touches), already correct on refs.
2. **Then SWS session 1** (this plan's repo work).
3. **Then the shared-helper follow-up** retrofits both packages and updates the
   coupling doc lines — done last to avoid a three-way collision on `lib/ai/`.

This ordering keeps each session's edits disjoint.

---

## 6. Session 1 — nix-agentic-tools repo (PR-able; `nix flake check`)

Phases for supervisor-worker-verifier. Load-bearing first.

### Phase A — Content build: real-file references (fixes the bug)

- Rework `packages/stacked-workflows/overlay.nix` so `stacked-workflows-content`
  produces self-contained skill dirs with **real** ref files (deref symlinks).
- Add `passthru.skills` = readDir-derived `name -> path` map rooted at the fixed
  skills dir (single source of truth).
- Verify: `cat` a built skill's `references/*.md` resolves; the 3 orphan refs are
  not bundled.

### Phase B — Modules: drop prefix, re-add HM emission, DRY

- HM module (`modules/homeManager/default.nix`): keep `gitPreset`; **add** skills
  (`ai.skills` from `passthru.skills`, unprefixed) + router (`ai.instructions`,
  no `paths`). Remove the git-config-only header comment.
- devenv module (`modules/devenv/default.nix`): consume `passthru.skills`
  unprefixed; keep router; **drop** the dead `.claude/references/*` block (refs
  now travel inside the skill).
- Claude router double-emit (named instruction → `CLAUDE.md` aggregate _and_
  `.claude/rules/<name>.md`) is **accepted as-is for now** — do NOT rework the
  rules tooling to fix it (out of scope, see §1a).

### Phase C — Dev-repo self-consumption (DECIDED: Option B, both packages)

Chosen: **wire both `stacked-workflows` AND `living-workflow` devenv modules into
this repo's `devenv.nix` with a `dev-` prefix** — both are under active
development, so both need shadow-free in-repo dev copies. Consumers/global stay
unprefixed (`stack-*`, `living-workflow`).

- **SWS:** `devenv.nix` consumes `passthru.skills` re-keyed `dev-stack-*`
  (`lib.mapAttrs'`). Update `enterTest` asserts to `dev-stack-*`.
- **LW:** wire `./packages/living-workflow/modules/devenv` in and install its
  skill re-keyed `dev-living-workflow` (acts on LW tech-debt #2, adds the prefix).
  Wrinkle: LW's skill is `mkSkill`-generated with a scope-specific state base, so
  re-keying needs either a direct `mkSkill` call in `devenv.nix` (devenv state
  base) or the shared helper below — NOT a new module option (no scope creep).

This makes the prefix rule **uniform** (both packages, dev-repo devenv prefixed)
and strengthens the case for pulling the shared helper (§9) into this session.

### Phase D — Tests (do it right)

- `checks/module-eval.nix`: assert HM now HAS `stack-*` skills + router; invert
  the 3 `*-hm-no-*-leak` guards; devenv asserts `stack-*` keys + router; add an
  `evalDevenv`-based ref-resolution assertion (guard against the dangling-refs
  regression); dev-repo checks use the dev prefix.

### Phase E — Cleanup (live surfaces + dangling ref; leave historical journals)

- Repoint the dangling `docs/stacked-workflows-scope-fix-plan.md` reference
  (module comments, `dev/fragments/ai-module/ai-module-fanout.md`,
  `.github/instructions/ai-module.instructions.md`) → commit `940ec54c`.
- Update the stale dev fragment `dev/fragments/stacked-workflows/development.md`
  (it describes the removed `stacked-workflows.integrations` option and the old
  `modules/stacked-workflows/` layout).
- Update `sws-` mentions on live surfaces: `dev/skills/repo-review/personalities/
agentic-ux.md` (the "sws- exception" note), `dev/docs/getting-started/
devenv.md` example, ai-module fanout narrative.
- Leave historical plan journals (`docs/plan.md`,
  `docs/ai-factory-collision-refactor-plan.md`,
  `docs/monorepo-restructure-assessment.md`) as point-in-time records.

### Phase F — Validate

- `nix flake check` (guarded, single-job); confirm skills resolve their refs in
  both scopes via the new eval tests.

---

## 7. Session 2 — nixos-config activation (HITL)

- Bump the nix-agentic-tools pin to the session-1 commit.
- `stacked-workflows.enable = true` now installs skills + router **globally**;
  update the nixos-config comment accordingly.
- HITL rebuild/switch; live-verify: `~/.claude/skills/stack-*` +
  `~/.kiro/skills/stack-*` present and their `references/*.md` resolve; router in
  `~/.claude/CLAUDE.md` + `~/.kiro/steering/`.
- The `lib.isPath` trap is **RESOLVED** — upstream Claude `mkSkillEntry` now uses
  `lib.hm.strings.isPathLike`, so store-path STRINGS work (LW verified live on
  Claude + Kiro v3). Floor: keep the HM pin ≥ the `isPathLike` version (LW
  tech-debt #4) — a regression below it silently writes `SKILL.md` as path-text.
- Write the precedence memory (Section 8).

---

## 8. Precedence memory (to write in session 2)

- Claude Code skill precedence is **Enterprise > Personal (`~/.claude`) > Project
  (`.claude`) > Plugin > Bundled**, with **silent shadowing** (no warning).
- Consequence: once `stack-*` is installed globally, developing the skills
  _in this repo_ means the global copy shadows the project copy — in-repo edits
  do not take effect.
- Chosen workaround: the dev repo's devenv installs under a **prefix** so its
  copies are distinctly invocable and unshadowed. (Alternative:
  `skillOverrides: { "stack-fix": "off" }` in `.claude/settings.local.json`.)
- Kiro reads global `~/.kiro/` for skills + steering (hooks are workspace-local);
  correct the stale "v3 is workspace-local-only" note.

---

## 9. Shared skill-packaging helper (LW landed → safe to pull into S1)

- Extract `lib/ai/mkSkillPackageModule.nix` (+ a deref-and-copy reference helper
  and a dev-prefix re-key helper) that emits the per-backend `enable` +
  `ai.skills` wiring from a spec, tolerating both a `./` path literal (SWS static)
  and a generated store-path string (LW baked — strings now proven via
  `isPathLike`).
- Now that BOTH packages need the same dev-prefixed in-repo devenv wiring
  (§Phase C), this is strongly motivated. LW has landed, so the earlier three-way
  collision risk is gone — **approved IN S1 (2026-07-18)**. Retrofit both
  packages; update the §4 coupling lines.

---

## 10. Open items / risks

- **In-repo devenv + prefix — OPEN** (§Phase C, Option A vs B). The only decision
  gating execution. LW needs no prefix regardless (its devenv isn't wired in-repo).
- **Claude router double-emit** — accepted as-is; do NOT rework the rules tooling
  (out of scope, §1a).
- **`lib.isPath` trap — RESOLVED** — upstream uses `isPathLike`; strings work (LW
  verified). Floor: keep HM ≥ the `isPathLike` version (LW tech-debt #4).
- **3 orphan refs** — kept in source, unbundled; revisit after the user reads
  them.
- **Kiro `defaults.outputPath` staleness** (`.config/kiro/steering/`) — noted by
  validation; out of scope unless it causes a stray write.
