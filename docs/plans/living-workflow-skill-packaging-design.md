# Living-workflow skill-packaging + XDG relocation — design (B+C)

**Status:** design draft for operator approval (PASS 14, the B+C child work
plan). Working doc — untracked; do not commit unless asked. Supersedes nothing;
grounds the implementation plan.

**Scope:** the **skill** slice (package the workflow as an installable skill) +
the **xdg** slice (relocate framework/plan working state to an XDG base
directory). The **versioning** slice is already shipped (master v3/v4,
R-DIR-25/26), so this design does not touch it. This is a **build**, routed as
an operator-directed build-class child plan (R-DIR-28), not a groom-fold.

**Sources this design is grounded in:** the operator's handoff
(`living-workflow-skill-packaging-handoff.md`, decisions 1–5 + open B/C/D/E),
and three repo reviews run this session — the skill-packaging mechanism, the
exact XDG doc edit-inventory, and the HM/XDG/Kiro-v3 facts.

---

## 1. The two decisions, restated precisely

- **XDG layout (item B → all plans to XDG):**
  `<xdg-state>/living-workflows/<main-clone-dirname>/<workflow-name>/…`
  - `<xdg-state>` is `config.xdg.stateHome` (default `~/.local/state`),
    **Nix-resolved and baked at activation** — not a runtime `$XDG_STATE_HOME`
    read.
  - `<main-clone-dirname>` is the **original clone's directory name** — the
    worktree that holds the real `.git/` _directory_ (git's main worktree /
    common dir), stable across every linked worktree. Resolved at runtime as
    `basename(dirname(realpath(git rev-parse --git-common-dir)))`.
  - `<workflow-name>` disambiguates multiple workflows in one clone (e.g.
    `living-workflow-backlog`).
- **Install (decision 1 + operator):** global **user** install via home-manager,
  reusing the repo's existing skill-packaging (`packages/stacked-workflows/` is
  the template). One enable that fans out to every _configured_ ecosystem, with
  a per-ecosystem override. No devenv dependency (the work repo has direnv +
  devShell only).

### The git-common-dir role change (the terminology trap, called out)

The **old** rule (bootstrap L234) says: resolve a plan's root via
`git rev-parse --show-toplevel` and **do NOT** use the shared common git dir.
Under this design that inverts in a specific way:

- The **location** is XDG (not the common-dir parent inside the repo — that
  superseded "put it beside `.git`" mechanism stays dead, per the xdg entry).
- The common git dir returns only as the **namespace key** (its parent's
  basename), never as the location.

So `git rev-parse --git-common-dir` goes from _forbidden-for-location_ to _the
source of the key_. The plan must state this explicitly so the fold neither
resurrects the old location rule nor drops the still-needed common-dir
computation.

### Behavioral consequence to confirm

Old model: plan state lived at `<worktree>/.living-workflows/<plan>/`, so it was
**per-worktree** and **died with the worktree** ("location encodes durability").
New model: plan state is keyed by `<main-clone-dirname>/<workflow-name>`, so it
now **survives worktree teardown** and is **shared across all worktrees of one
clone that run the same-named workflow**. For the framework backlog (one per
clone) that is exactly the durability win. For an ordinary feature plan it means
two worktrees running a same-named plan share one state dir. Intended per "all
plans to XDG" — flagged for explicit confirmation, not assumed.

---

## 2. Target architecture

### 2a. Machinery = a new package `packages/living-workflow/` (mirrors `stacked-workflows`)

The repo's skill packaging is a "content package" pattern: a package ships skill
source dirs in the Nix store and feeds them into the cross-ecosystem `ai.skills`
pool behind its own `enable` toggle. `packages/stacked-workflows/` is the
working template.

Files (mirroring the template):

- `packages/living-workflow/skills/living-workflow/SKILL.md` — the **router**
  (create / resume / groom entry points).
- The **machinery docs MOVE into the package** (D1 = move) as skill references,
  progressively disclosed (decision 3): run-time loads the master bootstrap +
  schema; edit-time (groom) loads the backlog-rules doc; modify-time loads the
  changelog. Co-locating them here collapses the `../living-workflow/…`
  inter-doc references to same-dir siblings; the boundary references (the
  `state.json` baseline path, version→commit resolution) re-root.
- `packages/living-workflow/overlay.nix`, `default.nix` (barrel exposing
  `modules.{homeManager,devenv}`), and the two modules.
- Register the barrel in `packages/default.nix`; register the overlay in
  `flake.nix` only if we ship a store `-content` derivation. The modules
  auto-discover via `collectFacet` — no manual flake edit.

**Install path = the HM module** (opposite scope choice from
`stacked-workflows`, which contributes from its _devenv_ module for
project-local skills). Because the `ai.skills` pool is **per-eval** (HM and
devenv are separate `evalModules`), contributing from the HM module is what
lands the skill in the user-global `~/.claude/skills/` + `~/.kiro/skills/` —
i.e. "machinery installs once, globally." devenv parity is a second, independent
contribution (config-parity rule), declared in the devenv module.

**Enable UX:** the package exposes `living-workflow.enable`; internally it
writes `ai.skills.living-workflow = ./skills/living-workflow` (a module-relative
`./` **path literal** — not a passthru string, to avoid the `lib.isPath` "writes
the path as text" trap). `ai.skills` fans out to every _enabled_ ecosystem; a
consumer still turns ecosystems on themselves (`ai.claude.enable`,
`ai.kiro.enable`) — there is deliberately no master `ai.enable`.

### 2b. The skill is Nix-_generated_, because it bakes the XDG base

`ai.skills` entries are directory paths baked to the store, but our SKILL.md
must contain the `config.xdg.stateHome`-derived base. So the skill content is
**generated at eval time** (the repo's established pattern: pass the
Nix-resolved absolute path into a builder — as `autoMemory.nix` bakes
`config.home.homeDirectory` — and emit the file with the value interpolated).
The base (`<xdg-state>/living-workflows/`) is baked; the
`<main-clone-dirname>/<workflow-name>` tail is computed by the agent at run time
via git. This repo currently has **zero** `config.xdg.stateHome` consumers, so
this is the first — the one existing XDG touchpoint uses the
runtime-`$XDG_STATE_HOME` anti-pattern we are replacing.

### 2c. Instances = plan working state under XDG

Each plan (framework backlog and any downstream plan) keeps its own
`state.json` + WAL journal (+ `entries/` for the framework-channel host) under
`<xdg-state>/living-workflows/<main-clone-dirname>/ <workflow-name>/`. Each plan
doc is self-contained and references the one master by version pin (DRY); a plan
is free to evolve its own generated copy. Web mode has no repo, so it keeps the
in-doc state block — the XDG keying is CLI-only.

---

## 3. The XDG doc relocation (the protocol edits)

This is a **master-protocol change**: rewrite the STATE SUBSTRATE rules so state
resolves to XDG, bump the master version (v5 → v6), and author a migration
entry. Per **D1 (move)** the docs are physically relocated into the package as
part of this step, so the 15 surfaces are edited in their new home and the
boundary references re-root. The edit-inventory review found **15 edit
surfaces**; the load-bearing ones:

- **`living-plan-bootstrap.md` STATE SUBSTRATE** — rewrite the
  gitignored-working-state bullet, the
  `<WORKTREE_ROOT>/.living-workflows/<plan>/` tokens, and the "resolve
  WORKTREE_ROOT via `--show-toplevel`, do NOT use the common git dir" rule (now
  the git-common-dir-parent basename is the key).
- **FRAMEWORK-CHANNEL LOCATION bullet** — drop the per-deployment ecosystem
  pointer; XDG replaces it (a standard resolution, so the "never hardcode" rule
  is still satisfied). This dissolves the cross-repo "which worktree root" fork
  outright.
- **ECOSYSTEM ADAPTER / CAPTURE / bootstrap step 2 / WEB→CLI transition /
  SCAFFOLD** — repoint every reference to the framework-channel pointer and the
  working-dir creation path.
- **`.gitignore`** — with all plans in XDG, nothing writes to
  `<repo>/.living-workflows/` anymore; that ignore line becomes vestigial (keep
  as belt-and-suspenders or remove — plan decides).
- **`state.schema.json` execution_mode description +
  `living-workflow-backlog.md` "What lives here" table + `changelog.md`** — must
  all move in lockstep (the master's ripple + DRY-sync invariants).

### Leak-safety improves

Framework state moving **out of any repo** means it can no longer be committed
by accident — a strict improvement over "gitignored by location." The
`state.json` `living_doc_baseline.path` is currently a repo-relative path
(`../../docs/plans/living-workflow/...`); from XDG that relative anchor breaks,
so the plan must re-root it (absolute, or resolved from the current repo via
git). Noted as a required edit, not an afterthought.

---

## 4. The framework-backlog self-migration (the delicate part)

This very backlog's own working state currently lives at
`<repo>/.living-workflows/living-workflow-backlog/`. Relocating to XDG means
**moving live state mid-stream** to
`<xdg-state>/living-workflows/nix-agentic-tools/living-workflow-backlog/`,
updating every pointer (the baseline path, the kickoff resume instructions), and
proving the backlog still resumes from the new location. This is the
highest-risk step and the reason B+C is a build session, not a doc edit. The
plan sequences it last, after the scheme + package are in place and verified,
with a tested move (copy → verify resume → remove old) so a botched move cannot
strand the backlog.

---

## 5. Kiro-v3 status (item C-a PROVEN)

- **Both Claude Code and Kiro v3 are shipping targets.** Claude Code installs
  skills to `~/.claude/skills/<name>/` (upstream HM). Kiro v3 global skills-dir
  loading is now **proven**: the operator verified a global user skill at
  `~/.kiro/skills/gh-repo-settings/` loads and works in a live v3 environment.
  The earlier docs-only uncertainty is resolved — the factory's
  `~/.kiro/skills/` route (referenced via `skill://`) is a real, working target,
  not NEEDS-EVIDENCE.
- **Item C remainder (light follow-up, not a blocker):** whether Nix should also
  write the `skill` capability (+ `fs_write` to the XDG state path) into
  `~/.kiro/settings/permissions.yaml`. Since `gh-repo-settings` already
  activates in the operator's env, that capability is evidently granted there
  (default-allow or existing config); the plan installs the skill and wires
  `permissions.yaml` only if activation proves to need it.
- **No hook needed:** capture-at-close is agent-driven (reflection mode), not a
  hook — and v3 hooks are workspace-local + must be real files (store symlinks
  skipped), so a global hook wouldn't work anyway.
- **Invocation (item D):** NL / skill-description is the cross-surface handle;
  Kiro v3 has no user-defined slash commands. No decision needed.

---

## 6. Changelog-to-web (item E) — resolved by derivation

The changelog is modify-time-only; web is a run-time surface with no pin to
reconcile; the run-time / modify-time layering (decision 3) already says the
changelog never loads on a run. So the changelog is **not part of the web
payload**. No new rule — it falls out of decision 3. (Operator veto pending.)

---

## 7. Verification strategy (build-verification, not tuning-prosecution)

- **Nix eval / build:** `nix flake check`; the module evaluates;
  `living-workflow.enable = true` yields
  `programs.claude-code.skills ? living-workflow` (mirror the existing
  `checks/module-eval.nix` pattern).
- **Install smoke:** the generated SKILL.md contains the correct baked XDG base;
  skill dir materializes under `~/.claude/skills/`.
- **End-to-end:** run a plan (create/resume) and confirm state lands at
  `<xdg>/living-workflows/<clone>/<workflow>/`, and that the git-common-dir key
  is stable from a linked worktree.
- **Doc consistency:** master version bump + migration entry; schema / changelog
  / backlog table move in lockstep; DRY-sync close invariant holds;
  positive+negative grep controls on the relocation.
- **Backlog self-migration:** prove resume from the new XDG location before
  removing the old.
- **Execution style:** supervisor-worker-verifier (operator standing preference
  over `superpowers:executing-plans`).

---

## 8. Sequencing (for the build session)

1. Define the XDG resolution scheme + rewrite the STATE SUBSTRATE protocol (the
   15 surfaces), master version bump + migration entry.
2. Build `packages/living-workflow/` (router SKILL.md + bundled machinery, XDG
   base baked; HM primary, devenv parity; register barrel/overlay).
3. Verify install + end-to-end on Claude Code; park Kiro-v3 activation as
   NEEDS-EVIDENCE.
4. Migrate the framework backlog's own state to XDG (tested move; prove resume).
5. Full verification pass + doc-consistency + emit the delivered-record (the
   `DROPPED:<delivered>` drain + build learnings) so the entry drains and the
   design→build handoff is closed.

---

## 9. Sub-decisions — RESOLVED

- **D1 — master-doc source location: MOVE.** The canonical machinery docs
  (master bootstrap, schema, changelog, backlog-rules) move into
  `packages/living-workflow/skills/living-workflow/references/`, making the
  package self-contained. Consequences the plan absorbs: (a) inter-doc
  references simplify — master + backlog-rules become same-dir siblings, killing
  the `../living-workflow/…` path-drift; (b) boundary ripple — the `state.json`
  baseline path, any external reference to `docs/plans/living-workflow*/`, and
  version→commit resolution re-root; (c) `docs/plans/living-workflow/` +
  `docs/plans/living-workflow-backlog/` are emptied of machinery (this design
  doc + the handoff stay in `docs/plans/`); (d) a running plan reads the
  INSTALLED skill copy (always present via HM), while version→commit
  reconciliation uses the nix-agentic-tools source checkout when present.
- **D2 — plan-state-shared-per-clone: CONFIRMED.** Plan state is clone-scoped —
  survives worktree teardown, shared across worktrees of one clone running the
  same-named workflow.
- **D3 — framework-backlog self-migration: CONFIRMED.** This backlog
  self-migrates to XDG within the plan (tested move: copy → prove resume →
  remove old).
- **E — changelog-to-web: CONFIRMED not in the web payload** (falls out of the
  run-time/modify-time layering).
- **Item C-a — Kiro v3 global skill loading: PROVEN** (operator-verified
  `~/.kiro/skills/gh-repo-settings/` in a live v3 env). C-b (`permissions.yaml`
  capability via Nix) is a light follow-up, not a blocker.
