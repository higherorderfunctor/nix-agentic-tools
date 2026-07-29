# Living-workflow skill-packaging + XDG relocation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: execute via
> **supervisor-worker-verifier** (operator standing preference).
> `superpowers:subagent-driven-development` (fresh subagent per task + two-stage
> review) is the compatible analog; do NOT use `superpowers:executing-plans`.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Package the living-workflow as an installable, user-global Nix skill
and relocate all plan working state to an XDG base directory keyed by clone +
workflow name.

**Architecture:** A new self-contained content package
`packages/living-workflow/` (mirroring `packages/stacked-workflows/`) ships the
machinery docs + a Nix-generated router `SKILL.md` and contributes it to the
cross-ecosystem `ai.skills` pool **from its home-manager module** (so it
installs user-globally to `~/.claude/skills/` and `~/.kiro/skills/`). The skill
bakes the `config.xdg.stateHome` base at activation; the agent computes the
`<main-clone-dirname>/<workflow-name>` tail at runtime via git-common-dir. The
STATE-SUBSTRATE protocol is rewritten to resolve state there; the framework
backlog self-migrates last.

**Tech Stack:** Nix (flakes, home-manager, devenv), the repo's `mkAiApp`
factory, `check-jsonschema`, markdown protocol docs.

**Design source of truth:**
`docs/plans/living-workflow-skill-packaging-design.md` (all decisions RESOLVED).
Umbrella context: `docs/plans/living-workflow-skill-packaging-handoff.md`. This
plan is a working doc — untracked; commits are per-task under R-DIR-24
backlog-owned-paths auth + operator gate.

## Global Constraints

- **Commits:** Conventional Commits
  (`feat`/`fix`/`refactor`/`docs`/`chore`/`build`/`test`), lowercase imperative,
  scoped (e.g. `feat(living-workflow): …`). Co-author footer per repo
  convention.
- **Bash:** full strict mode in every script/heredoc — `set -euETo pipefail` +
  `shopt -s inherit_errexit`.
- **Ordering:** alphabetical within categorical groups (attrsets, lists,
  tables).
- **DRY / YAGNI:** one source of truth; no premature knobs.
- **Nix path types:** skill sources are **module-relative `./` path literals**,
  never passthru strings (a string silently trips `lib.isPath` and writes the
  path AS text into SKILL.md).
- **`ai.skills` pool is per-eval:** an HM contribution is invisible to devenv
  and vice-versa — wire both independently (config-parity rule).
- **Verification is blocking:** `nix flake check` green, `check-jsonschema`
  valid (positive + negative control), grep relocation with positive controls,
  before claiming any task done.
- **Leak-safety:** this repo's own first-party tooling is nameable; protect
  private/work context (none here).

**Workflow-name for the framework backlog:** `living-workflow-backlog`. **XDG
path shape:**
`<config.xdg.stateHome>/living-workflows/<main-clone-dirname>/<workflow-name>/…`.

**Runtime clone-name recipe (used in the SKILL.md protocol + STATE SUBSTRATE):**

```bash
main_root="$(dirname "$(realpath "$(git rev-parse --git-common-dir)")")"
clone_name="$(basename "$main_root")"   # stable across every linked worktree
```

---

## Phase 0 — Grounding (build session reads first, no deliverable)

Before Task 1, read: this plan; the design doc; the edit inventory in
§"Reference: XDG edit inventory" below; and the template package verbatim —

- `packages/stacked-workflows/{default.nix,overlay.nix}`
- `packages/stacked-workflows/modules/{homeManager,devenv}/default.nix`
- `packages/claude-code/lib/mkClaude.nix` (skills wiring `:353` HM, `:555`
  devenv)
- `packages/kiro-cli/lib/mkKiro.nix` (skills → `~/.kiro/skills/`; `permissions`
  `capability="skill"` `:236,438`)
- `packages/kiro-cli/lib/autoMemory.nix` (the baked-absolute-path template:
  param `home` `:51`, bake `:90`)
- `lib/ai/sharedOptions.nix` (`ai.skills` `:146`), `lib/ai/app/hmTransform.nix`
  (merge `:38,52`), `lib/ai/hm-helpers.nix` (`mkSkillEntries` `:48`,
  `mkDevenvSkillEntries` `:94`), `lib/ai/dir-helpers.nix` (`skillsFromDir`
  `:73`)
- `flake.nix` (`collectFacet` `:101`, `homeManagerModules` `:128`,
  `overlays.default` `:96,114`), `packages/default.nix`
- `checks/module-eval.nix` (the `ai.skills` fanout assertion pattern)

Re-read the current text of any doc before editing it — it may have reflowed
since the inventory.

---

## Phase 1 — Package skeleton + doc relocation (D1 = move)

### Task 1: Scaffold `packages/living-workflow/` and register the barrel

**Files:**

- Create: `packages/living-workflow/default.nix` (barrel),
  `packages/living-workflow/overlay.nix`,
  `packages/living-workflow/modules/homeManager/default.nix`,
  `packages/living-workflow/modules/devenv/default.nix`,
  `packages/living-workflow/skills/living-workflow/` (dir, target for Task 2)
- Modify: `packages/default.nix` (add
  `living-workflow = import ./living-workflow;`, alphabetical), `flake.nix` (add
  `livingWorkflowOverlay` to `overlays.default` only if shipping a `-content`
  derivation)

**Interfaces:**

- Produces: package option `living-workflow.enable` (bool); a barrel exposing
  `modules = { devenv = ./modules/devenv; homeManager = ./modules/homeManager; }`.

- [ ] **Step 1 (failing check):** Add to `checks/module-eval.nix` an assertion
      that with `living-workflow.enable = true`,
      `config.programs.claude-code.skills ? living-workflow`. Mirror the
      existing sws assertion exactly.
- [ ] **Step 2:** `nix flake check` → EXPECT FAIL (option
      `living-workflow.enable` undefined).
- [ ] **Step 3:** Create the barrel + overlay + two modules by mirroring
      `packages/stacked-workflows/` structure. HM module declares
      `options.living-workflow.enable = lib.mkEnableOption "living-workflow";`
      and `config = lib.mkIf cfg.enable { … }` (empty for now). devenv module
      mirrors with its own `enable`. Register the barrel in
      `packages/default.nix` (alphabetical).
- [ ] **Step 4:** `nix flake check` → still FAIL on the skills assertion (no
      skill wired yet), but the option now evaluates. Confirm no eval errors.
- [ ] **Step 5:** Commit
      `feat(living-workflow): scaffold package skeleton + enable toggle`.

### Task 2: Move the machinery docs into the package (D1)

**Files:**

- `git mv` → `docs/plans/living-workflow/living-plan-bootstrap.md`,
  `docs/plans/living-workflow/state.schema.json`,
  `docs/plans/living-workflow/changelog.md`,
  `docs/plans/living-workflow-backlog/living-workflow-backlog.md` →
  `packages/living-workflow/skills/living-workflow/references/`
- Modify: every same-dir cross-reference (the `../living-workflow/…` links in
  the backlog-rules doc collapse to same-dir siblings); leave
  `docs/plans/living-workflow-skill-packaging-{handoff,design}.md` and this plan
  in place.

- [ ] **Step 1:** `git mv` the four docs into `references/`. Verify with
      `git status` that they're tracked moves.
- [ ] **Step 2:** Grep for cross-references that now break:
      `rg -n '\.\./living-workflow/' packages/living-workflow/skills/living-workflow/references/`
      and `rg -n 'docs/plans/living-workflow' packages docs` (positive control:
      expect the handoff/design to still reference `docs/plans/…` as historical,
      but the machinery docs should reference siblings).
- [ ] **Step 3:** Repoint the backlog-rules doc's DRY-by-reference pointers
      (`../living-workflow/living-plan-bootstrap.md`,
      `../living-workflow/state.schema.json`, `../living-workflow/changelog.md`)
      to same-dir (`./living-plan-bootstrap.md`, etc.). Re-read current text
      first (it may have reflowed).
- [ ] **Step 4:**
      `check-jsonschema --check-metaschema packages/living-workflow/skills/living-workflow/references/state.schema.json`
      → EXPECT PASS (schema still valid after move).
- [ ] **Step 5:** Commit
      `refactor(living-workflow): move machinery docs into the package (D1)`.

---

## Phase 2 — XDG protocol rewrite + version bump

> Doc edits use the verbatim current tokens from the "Reference: XDG edit
> inventory" section. Re-read each surface's current text before editing. After
> each edit, grep the OLD token (expect gone) with a positive control (a token
> that should remain), then the NEW token (expect present).

### Task 3: Rewrite the STATE SUBSTRATE + FRAMEWORK-CHANNEL LOCATION rules for XDG

**Files:**

- Modify:
  `packages/living-workflow/skills/living-workflow/references/living-plan-bootstrap.md`
  (STATE SUBSTRATE ~L225–272; SCAFFOLD ~L280; WEB→CLI ~L292–294; CAPTURE ~L539;
  bootstrap step 2 ~L704–706)

**Interfaces:**

- Produces: the protocol rule "state resolves to
  `<baked-xdg-base>/<clone_name>/<workflow-name>/`, clone_name via
  git-common-dir parent basename" — consumed by the SKILL.md router (Task 6) and
  the schema (Task 4).

- [ ] **Step 1:** Rewrite the GITIGNORED WORKING STATE bullet: replace
      `<WORKTREE_ROOT>/.living-workflows/<plan>/` with the XDG path shape;
      **invert** the "resolve WORKTREE_ROOT via `git rev-parse --show-toplevel`;
      do NOT use the shared common git dir" rule — now: location is XDG, and the
      git-common-dir parent **basename is the namespace key** (include the
      runtime recipe from Global Constraints). State the role change explicitly
      so the old location-at-common-dir mechanism is not resurrected.
- [ ] **Step 2:** Rewrite the FRAMEWORK-CHANNEL LOCATION bullet: **drop** the
      per-deployment ecosystem pointer; XDG is the single machine-global
      canonical location (a standard resolution, so "never hardcode" holds).
      Note this dissolves the cross-repo "which worktree root" fork.
- [ ] **Step 3:** Repoint SCAFFOLD, WEB→CLI transition, CAPTURE, and
      bootstrap-step-2 references to the XDG location (keep web-mode's in-doc
      state block unchanged — XDG keying is CLI-only).
- [ ] **Step 4:** Grep controls:
      `rg -n 'WORKTREE_ROOT|\.living-workflows/<plan>|per-deployment pointer'`
      the bootstrap → EXPECT only intended residuals;
      `rg -n 'xdg.stateHome|git-common-dir|clone'` → present.
- [ ] **Step 5:** Commit
      `refactor(living-workflow): resolve working state to XDG (state substrate)`.

### Task 4: Re-root boundary references; schema + backlog table + `.gitignore` in lockstep

**Files:**

- Modify: `references/state.schema.json` (execution_mode description ~L38),
  `references/living-workflow-backlog.md` ("What lives here" table ~L41–49;
  `.living-workflows/` refs ~L242, 254–255), `.gitignore` (L49–50), and the
  `state.json` `living_doc_baseline.path` re-root note

**Interfaces:**

- Consumes: the XDG rule from Task 3. Produces: a schema description + backlog
  table that match the protocol (ripple invariant); a baseline-path resolution
  that works from XDG.

- [ ] **Step 1:** Update the schema `execution_mode` description: replace
      `<WORKTREE_ROOT>/.living-workflows/<plan>/` with the XDG shape. Keep it a
      description only.
- [ ] **Step 2:** Rewrite the backlog "What lives here" table rows
      (state.json/journal/entries) to the XDG path; update the "under
      `<WORKTREE_ROOT>`" prose. Keep the table a **reference** to the master's
      STATE SUBSTRATE (DRY-sync invariant), not a re-statement.
- [ ] **Step 3:** `.gitignore` L49–50: with all plans in XDG,
      `<repo>/.living-workflows/` is no longer written. Decide: keep the ignore
      line as belt-and-suspenders (recommended — cheap safety) and update its
      comment, OR remove it. Record the choice in the commit body.
- [ ] **Step 4:** Re-root `living_doc_baseline.path`: it is currently
      repo-relative
      (`../../docs/plans/living-workflow/living-plan-bootstrap.md`) and breaks
      from XDG. New resolution: the path is relative to the **installed skill**
      (same-dir `./living-plan-bootstrap.md` for a running plan), and
      version→commit reconciliation resolves against the nix-agentic-tools
      source checkout. Update the schema `living_doc_baseline` description
      accordingly.
- [ ] **Step 5:**
      `check-jsonschema --schemafile references/state.schema.json <the live backlog state.json>`
      → EXPECT PASS (positive) + a corrupted copy → EXPECT FAIL (negative
      control).
- [ ] **Step 6:** Commit
      `refactor(living-workflow): ripple XDG relocation to schema, backlog table, gitignore`.

### Task 5: Master version bump v5→v6 + migration entry

**Files:**

- Modify: `references/living-plan-bootstrap.md` (VERSION field),
  `references/changelog.md` (new entry), the live backlog `state.json`
  (`living_doc_baseline.version`)

- [ ] **Step 1:** Assign the new master version (ordinal + distinctive label,
      per the versioning slice's hybrid form): `v6-<label>`. Update the master's
      VERSION field.
- [ ] **Step 2:** Author a judgment-based migration entry in `changelog.md` —
      this is a modifying change an upgrader must act on (state now lives in
      XDG; existing `<WORKTREE_ROOT>/.living-workflows/` state must migrate).
      Describe the upgrader action.
- [ ] **Step 3:** Re-pin `state.json.living_doc_baseline.version` to
      `v6-<label>` (via `jq`, atomic; re-validate with `check-jsonschema`).
- [ ] **Step 4:** Grep: `rg -n 'v5-onyx-meadow-cobalt'` across the moved docs →
      EXPECT only historical changelog references remain; the live baseline +
      master VERSION are v6.
- [ ] **Step 5:** Commit
      `docs(living-workflow): bump master to v6 + XDG migration entry`.

---

## Phase 3 — The Nix-generated skill + enable wiring

### Task 6: Author the router SKILL.md

**Files:**

- Create: `packages/living-workflow/skills/living-workflow/SKILL.md` (a
  template, `${…}` slot for the baked XDG base — see Task 7)

**Interfaces:**

- Produces: the router with three entry points (create / resume / groom), the
  runtime clone-name recipe, and progressive-disclosure pointers to
  `references/{living-plan-bootstrap.md,state.schema.json, living-workflow-backlog.md,changelog.md}`.

- [ ] **Step 1:** Write YAML frontmatter (`name: living-workflow`,
      `description:` a cross-surface NL trigger — the invocation handle per item
      D — `argument-hint`, `compatibility`), mirroring a
      `packages/stacked-workflows/skills/*/SKILL.md` header.
- [ ] **Step 2:** Write the router body: (a) **create** a plan, (b) **resume** a
      plan (the most common; read state from the XDG path), (c) **groom** the
      backlog (loads `references/living-workflow-backlog.md` edit-time only).
      Include the STATE-ROOT resolution (baked base + runtime clone-name recipe)
      and the progressive-disclosure rule (run-time loads bootstrap + schema;
      modify-time loads changelog).
- [ ] **Step 3:** Insert the XDG base as a substitution slot the Task-7
      generator fills (e.g. a sentinel `@XDG_STATE_BASE@`). Do NOT hardcode a
      home path.
- [ ] **Step 4:** Grep: `rg -n '@XDG_STATE_BASE@' SKILL.md` → present (one
      slot); no literal `/home/` or `$XDG_STATE_HOME` runtime read.
- [ ] **Step 5:** Commit `feat(living-workflow): add router SKILL.md`.

### Task 7: Nix-generate the skill baking `config.xdg.stateHome`; wire `ai.skills` (HM primary + devenv parity)

**Files:**

- Modify: `packages/living-workflow/modules/homeManager/default.nix` (the
  primary contribution), `packages/living-workflow/modules/devenv/default.nix`
  (parity), `packages/living-workflow/overlay.nix` (if shipping a `-content`
  derivation)

**Interfaces:**

- Consumes: `config.xdg.stateHome` (HM eval), the `SKILL.md` slot from Task 6,
  `references/`. Produces: `ai.skills.living-workflow = <generated-skill-dir>`
  under `living-workflow.enable`.

- [ ] **Step 1 (failing check):** the Task-1 `checks/module-eval.nix` assertion
      (`config.programs.claude-code.skills ? living-workflow` when enabled) is
      still red — confirm.
- [ ] **Step 2:** In the HM module, generate the skill dir at eval time: copy
      `skills/living-workflow/` and substitute `@XDG_STATE_BASE@` →
      `"${config.xdg.stateHome}/living-workflows"` (mirror the `autoMemory.nix`
      baked-absolute-path pattern — pass the Nix string into the builder; emit
      with the value interpolated). Feed the resulting dir into
      `ai.skills.living-workflow` **as a path** (mind the `lib.isPath` trap; use
      the repo's tolerant `mkSkillEntries` route if needed).
- [ ] **Step 3:** Mirror the contribution in the devenv module (separate eval;
      its own `enable`).
- [ ] **Step 4:** `nix flake check` → the module-eval assertion now PASSES;
      build the generated skill and
      `grep -r "$(echo "$HOME")/.local/state/living-workflows" <generated SKILL.md>`
      (or the eval-time value) → EXPECT the baked base present,
      `@XDG_STATE_BASE@` gone.
- [ ] **Step 5:** Register the overlay in `flake.nix` if a `-content` derivation
      is shipped.
- [ ] **Step 6:** Commit
      `feat(living-workflow): nix-generated skill with baked XDG base + ai.skills wiring`.

### Task 8: Consolidate module-eval checks

**Files:**

- Modify: `checks/module-eval.nix`

- [ ] **Step 1:** Add assertions: enabled →
      `programs.claude-code.skills ? living-workflow` AND (Kiro path)
      `programs.kiro-cli.skills ? living-workflow`; disabled → absent. Mirror
      the sws pattern.
- [ ] **Step 2:** `nix flake check` → EXPECT PASS.
- [ ] **Step 3:** Commit
      `test(living-workflow): module-eval assertions for skill fanout`.

---

## Phase 4 — Verify, self-migrate, drain

### Task 9: Install + end-to-end verification (Claude Code + Kiro v3)

- [ ] **Step 1:** Build the HM activation for a test profile (or `nix build` the
      skill derivation) and confirm the skill materializes at
      `~/.claude/skills/living-workflow/` and `~/.kiro/skills/living-workflow/`
      (Kiro path proven via the `gh-repo-settings` precedent).
- [ ] **Step 2:** Confirm the installed `SKILL.md` contains the correct baked
      `config.xdg.stateHome` base.
- [ ] **Step 3 (end-to-end):** From a **linked worktree**, run the clone-name
      recipe and confirm it returns the **main clone** basename (not the
      linked-worktree name). Create a throwaway plan; confirm state lands at
      `<xdg-state>/living-workflows/<clone_name>/<plan>/`.
- [ ] **Step 4 (Kiro activation, item C-b):** confirm the skill activates in v3;
      only if activation fails, wire the `skill` capability into
      `~/.kiro/settings/permissions.yaml` via `mkKiro`'s `permissions` option
      (`capability = "skill"`) and re-test. Otherwise leave permissions to the
      user's env.
- [ ] **Step 5:** Journal results; no commit (verification only).

### Task 10: Self-migrate the framework backlog state to XDG (tested move)

> Highest-risk step. Order: copy → prove resume → only then remove old. Never
> move-before-verify.

**Files:**

- Move:
  `<repo>/.living-workflows/living-workflow-backlog/{state.json,journal.md,entries/,consistency-nits.md}`
  → `<xdg-state>/living-workflows/nix-agentic-tools/living-workflow-backlog/`
- Modify: the backlog kickoff/resume instructions to resolve the XDG path

- [ ] **Step 1:** `cp -a` the backlog working dir to the XDG destination (do NOT
      delete the source yet).
- [ ] **Step 2:**
      `check-jsonschema --schemafile packages/living-workflow/skills/living-workflow/references/state.schema.json <xdg>/…/state.json`
      → EXPECT PASS at the new location.
- [ ] **Step 3:** Prove resume: from the new location, confirm
      `current_position.next_action` reads and the register (`open_items`) is
      intact; confirm `living_doc_baseline.path` resolves under the new scheme.
- [ ] **Step 4:** Only after Steps 2–3 pass, remove the old
      `<repo>/.living-workflows/living-workflow-backlog/`.
- [ ] **Step 5:** Commit any committed-surface changes (kickoff/resume text);
      the moved state is gitignored/uncommitted by nature.

### Task 11: Full verification pass + emit the delivered-record (drain)

- [ ] **Step 1:** Run the whole verification battery: `nix flake check` green;
      `check-jsonschema` valid (positive + negative control); grep the
      relocation across all surfaces with positive controls; DRY-sync invariant
      (backlog table references, not restates, the master); master v6 +
      migration entry present.
- [ ] **Step 2:** Confirm the design's §7 checklist is fully satisfied; journal
      any residual.
- [ ] **Step 3 (drain — the emit-at-end step baked into this plan per
      R-DIR-28):** write the DELIVERED-RECORD: mark the backlog entries
      `package-the-workflow-as-an-installable-skill` and
      `framework-channel-canonical-root-not-ephemeral-worktree` as
      `DROPPED:<delivered>` (the build shipped); capture build-time learnings as
      pending backlog items for the next grooming pass (never self-groom);
      update `current_position`. Validate state.
- [ ] **Step 4:** Commit
      `feat(living-workflow): package + XDG relocation shipped` and present for
      the operator's close acceptance.

---

## Reference: XDG edit inventory (verbatim current tokens — re-read before editing)

The 15 edit surfaces the grounding review found (paths relative to repo root;
**note Task 2 moves the first three files into
`packages/living-workflow/skills/living-workflow/references/`**, so edit them in
their NEW home):

1. `living-plan-bootstrap.md` STATE SUBSTRATE ~L232–241 —
   `GITIGNORED WORKING STATE … <WORKTREE_ROOT>/.living-workflows/<plan>/ …` and
   `resolve WORKTREE_ROOT freshly, e.g. git rev-parse --show-toplevel; do NOT use the shared common git dir`.
2. same, FRAMEWORK-CHANNEL LOCATION ~L242–253 —
   `Resolve that location at cold start into the ecosystem record (a per-deployment pointer); NEVER hardcode it …` +
   `A plan's OWN working state always resolves to its own worktree root.`
3. same, ephemeral-scratch ~L264–265 — `.living-workflows/<plan>/`.
4. same, SCAFFOLD HARNESS ~L280 — `<WORKTREE_ROOT>/.living-workflows/<plan>/`.
5. same, WEB→CLI ~L292, 294 — `.living-workflows/<plan>/` +
   `framework-channel location`.
6. same, IN-DOC STATE BLOCK + SELF-IDENTIFYING GENERATION ~L298–325
   (resolved-ecosystem record; keep web-mode intact).
7. same, CAPTURE ~L539 —
   `FRAMEWORK-CHANNEL LOCATION resolved from the ecosystem pointer`.
8. same, bootstrap step 2 ~L704, 706 —
   `<WORKTREE_ROOT>/.living-workflows/<plan>/` + `framework-channel location`.
9. `.gitignore` L49–50 — `# Living-workflow per-worktree working state …` +
   `.living-workflows/`.
10. `living-workflow-backlog.md` L41–42 — `working dir under <WORKTREE_ROOT>`.
11. same, L47–49 — three table rows
    `<WORKTREE_ROOT>/.living-workflows/living-workflow-backlog/{state.json,journal.md,entries/}`.
12. same, L242, 254–255 — `.living-workflows/` + cross-repo framework-channel
    paragraph.
13. `state.schema.json` L38 — execution_mode description
    `<WORKTREE_ROOT>/.living-workflows/<plan>/`.
14. `changelog.md` L38–39, 55, 141–145, 187–190, 261–262 — migration-guide prose
    naming the current location/pointer (new v6 migration entry required).
15. `living-workflow-skill-packaging-handoff.md` L73–82, 156–161, 196, 200–204,
    216–218 — operator XDG design record (reconcile/annotate; not protocol text
    — do not delete provenance).

**Two dependent-consistency rules (from the docs' own invariants):** (a)
VALIDATION-ON-UPDATE "ripple to ALL referencing surfaces in the same commit" —
schema (13) + changelog (14) + backlog mirrors move with the bootstrap; (b)
DRY-SYNC close invariant — the backlog table (11) stays a reference to the
master's STATE SUBSTRATE, edited in lockstep.

---

## END STATE — B+C SHIPPED (2026-07-18)

**Status: COMPLETE + verified.** Executed via supervisor-worker-verifier
(root-inline edits + read-only adversarial verifier fan-out; no edit fan-out).
All 4 phases / 11 tasks done.

### Shipped

Commits on `origin/refactor/ai-factory-architecture` (rebased onto the bot
dep-updates; full CI `nix flake check` **GREEN**):

- `b84cd3b3` refactor: move the 4 machinery docs →
  `packages/living-workflow/skills/living-workflow/references/`
  - relocate working state to XDG + master **v5-onyx-meadow-cobalt →
    v6-garnet-tundra-birch** + a new changelog migration entry (schema /
    backlog-table / `.gitignore` rippled in lockstep).
- `010d9cc3` feat: `packages/living-workflow/` — barrel +
  HM-primary/devenv-parity modules + `lib/mkSkill.nix` (Nix-generated skill
  baking `config.xdg.stateHome`); registered in `packages/default.nix`. **No
  overlay** (per-eval bake → a static `-content` derivation is the wrong place).
- `8db3719f` test: 5 `checks/module-eval.nix` assertions incl. the
  isPath/isString **trap-catcher** + an `xdg.stateHome` stub in `hmStubs`.

Installed + verified user-global on Claude Code + Kiro v3 (HM store symlinks
`~/.claude/skills/` + `~/.kiro/skills/`; `nixos-config` `ai/default.nix` has
`living-workflow.enable = true`). The live backlog self-migrated
`.living-workflows/living-workflow-backlog/` →
`~/.local/state/living-workflows/living-workflow-backlog/` (tested
copy→validate→prove-resume→remove-old; backup `../living-workflows-bk`);
delivered-record emitted (backlog `R-DIR-30`): the two B+C entries drained
`DROPPED:<delivered>`, `living_doc_baseline` re-pinned v6.

### Key decisions resolved during the build (differ from / sharpen the design)

- **Framework channel = first-party CLONE-LESS override.** The
  living-workflow-backlog is NOT repo-bound (it pairs with the installed skill)
  → `<xdg>/living-workflows/living-workflow-backlog/` (drop the `<clone-name>`
  segment); all living-workflow feedback lands in the ONE backlog. Ordinary
  plans stay per-clone `<xdg>/living-workflows/<clone-name>/<workflow-name>/`.
  This resolved a genuine design-doc-internal tension (design §1 "one per clone"
  vs plan/handoff "single machine-global canonical") that the adversarial
  verifier caught at build time.
- **clone-name recipe** =
  `basename "$(dirname "$(realpath "$(git rev-parse --git-common-dir)")")"` with
  a **dirname fallback** (`basename "$PWD"`) when git can't resolve.
- **ai.skills value shape** = the runCommand **outpath STRING** (`"${skill}"`),
  NOT the derivation (which trips `mkSkillEntries`' `isPath||isString` guard →
  path written as text). Works because modern upstream claude `mkSkillEntry`
  uses `lib.hm.strings.isPathLike` — the 2026-04-08 `claude-rules`
  "`lib.isPath`" fragment is SUPERSEDED upstream.

### Tech debt / follow-ups (for the review session)

1. **Hand-curated module lists (footgun).** Both `checks/module-eval.nix`
   (evalHm/evalDevenv module lists) and `devenv.nix` (imports L20–25) require
   MANUALLY adding each new package's modules — they do NOT auto-discover the
   way `flake.nix`'s `collectFacet` does. living-workflow was added to
   module-eval but (deliberately, see #2) not to `devenv.nix`. Consider
   auto-discovery to kill the manual-add footgun.
2. **living-workflow devenv module is NOT wired into this repo's `devenv.nix`**
   (decision point, not a bug). The devenv (project-local) parity is therefore
   inactive in nix-agentic-tools. This is fine as-is: the HM **user-global**
   install already provides the skill in every repo, so a project-local copy
   here is redundant for the single consumer. Wire it
   (`+ ./packages/living-workflow/modules/devenv` in the imports +
   `living-workflow.enable = true`) only if project-local parity in THIS repo is
   ever wanted.
3. **devenv base-source asymmetry.** The devenv variant bakes a runtime XDG
   shell-default (`${XDG_STATE_HOME:-$HOME/.local/state}/living-workflows`)
   because devenv has no `config.xdg.stateHome`; HM bakes the Nix-resolved
   absolute. Documented + acceptable, but asymmetric.
4. **Generated-skill requires a string-tolerant (modern) home-manager**
   (`isPathLike`). A pin regressing HM below that threshold would break the
   skill's directory materialization (silent path-as-text).
5. **Two external plan-doc refs to the old machinery path, left untouched:**
   `docs/plans/kiro-cli-auto-memory.md:850` (a CLOSED doc — "Do NOT reopen") and
   `docs/plans/prune-claude-plugin-and-memory-surface.md:5,183` (self-documents
   "re-verify paths if HEAD moved"). Re-root if desired.
6. **Pre-existing alphabetical drift** (not from this build):
   `packages/default.nix` has `mcp-services` before `mcp-language-server`. Fix
   in an ordering sweep if doing one.
7. The `-design.md` and `-handoff.md` working docs stay untracked (per
   no-commit-working-docs); this plan doc is tracked and now carries the end
   state.
