# Living-workflow skill-packaging — grooming handoff

Grooming **input** for the backlog item
`package-the-workflow-as-an-installable-skill`: operator decisions and open
questions from a design discussion. This is **not** a living plan — no
`state.json`, no lifecycle. Pass it to a living-workflow-backlog grooming
session.

## How to use this

- **Steering handed over out-of-session = capture, not fold-license.** Per the
  master's REFLECTION MODE and the steering-at-close ruling (R-DIR-17: operator
  steering handed over at close is reflection INPUT; a later session VALIDATES it
  adversarially as if it were a candidate, and never folds on sight), treat every
  "Decided" item below as a candidate to validate and then fold — not a
  pre-approved edit. The versioning item (open item A) collides with a prior
  decision and must be reconciled before folding.
- **This un-gates the item.** R-DIR-23 kept the package item operator-HOLD
  pending "the distribution + STRUCTURALLY-COLLAPSE discussion." This handoff
  opens that discussion, so the HOLD is lifted — the item is now groomable.
- **Fold generically.** The backlog-entry contract still governs: folds into the
  committed workflow docs are self-contained generic tunings with no repo/path/tool
  specifics. This handoff is deliberately concrete (it names paths, Kiro, XDG);
  sanitize on fold.

## The "why" (settles positioning)

The workflow is **for the operator**: one consistent plan/groom experience carried
across Claude web, Kiro CLI v3, and Claude Code. Open-sourced, but third-party
adoption is a non-goal. Consequences:

- The "pure-consumer machine can't reconcile" cap raised earlier is **moot** — the
  operator's machine always has the source repo checked out, so version→commit
  resolution always has git to read.
- The Kiro v3 `/spec` overlap is a **non-issue** — the operator brings his own
  cross-surface workflow; he is not positioning against or wrapping Kiro Specs.
  Record and drop.
- "Distribution" means **self-across-surfaces**, not fan-out-to-strangers. That
  scopes every distribution question down.

## Decided this session (validate, then fold)

1. **Install shape.** User-global skill installed by this repo's tooling, with an
   enable toggle. HM is the primary install path (the operator's Kiro work repos do
   not use devenv); devenv parity is still required by the repo's config-parity rule.
   **Machinery** (the skill: master + backlog-rules + schema + changelog) installs
   once, globally; **instances** (plan docs + their working state) stay per-repo.
   This machinery-vs-instance split is the correction to the entry's "co-locate all
   files" framing, which conflated committed machinery with per-worktree working
   state. Touches: a packaged skill under the repo's skill tooling; the STATE
   SUBSTRATE split (machinery global, instance local).

2. **Target runtime = Kiro CLI v3** (plus Claude web + Claude Code). v3 facts (see
   `docs/plans/kiro-v3-docs.txt`): Skills are available and user-installable
   (`~/.kiro/agents/`, `skill://` resources); activation is permission-gated by the
   `skill` capability in `permissions.yaml`; custom user slash commands are **not**
   documented (only the built-in `/spec`).

3. **Skill = lightweight router**; the other docs are exposed in the skill dir and
   progressively disclosed:
   - run-time (create a plan / resume a plan): master bootstrap protocol + schema.
   - edit-time (groom): the backlog-rules doc — loaded **only** when grooming, never
     on a plan run.
   - modify-time (reconcile a pin): the changelog — never on a run.

   This is the run-time/modify-time layering the entry's flat "co-locate" lacked.

4. **Web mode.** The master bootstrap (a self-contained, isolated artifact) is
   sendable to Claude web; its internal refs degrade to the IN-DOC STATE BLOCK per
   the existing SELF-IDENTIFYING GENERATION / web-mode design. (Whether the changelog
   is also sent to web is open — see item E.)

5. **Framework-channel entries → XDG base directory** (machine-global, single
   canonical), **replacing** both (a) the rejected hardcoded absolute path and (b)
   the per-deployment ecosystem pointer. XDG is a standard resolution, not a
   hardcoded path, so it satisfies the master's "never hardcode the framework-channel
   location" rule while removing the per-deployment-pointer indirection. This
   dissolves the cross-repo "which worktree root" fork: reflecting from **any**
   repo/surface, framework captures resolve to the same XDG location. Touches: STATE
   SUBSTRATE (framework-channel location), the repo `.gitignore` (framework state
   leaves `<WORKTREE_ROOT>/.living-workflows/`), the ECOSYSTEM ADAPTER (drop/relax
   the framework-channel-pointer capability).

6. **Version the docs.** The master (and its harness/changelog set) carries an
   explicit VERSION so feedback written against a past version can be mapped to the
   commit that shipped it and weighed against the current branch/commit. Rationale:
   web has no commit hash to pin (the raw-commit `living_doc_baseline` is degenerate
   in web mode), but a version string travels across web/kiro/claude. Reconciliation
   with the prior derive-from-history decision is open item A.

## Open items to weigh (groomer decides; park if not yet decidable)

**A. Versioning design (meatiest).** Reconcile with R-DIR-19/20, which chose
"changelog self-anchor = DERIVE-FROM-HISTORY, no self-stamp; keep the embedded commit
for the dependent pin." A VERSION is **assigned**, not a commit hash the file names
about itself, so it does **not** reintroduce the self-reference that decision killed.
Proposed reconciliation to evaluate: (i) the dependent pin becomes a VERSION (works in
web + across surfaces) instead of a raw commit; (ii) version→commit resolves by the
**same** derive-from-history technique (find the commit that set the master's version
field to X — analogous to "which commit added a changelog batch header"), or by a git
tag per version; (iii) **unify** the committed version with the web SELF-IDENTIFYING
GENERATION marker's generation counter — one monotonic version serving as web
generation marker, dependent pin, and changelog batch label. Define where the version
lives in each doc, its format, how web carries it, and how it interacts with ACTIVE
DRIFT RECONCILIATION and CHANGELOG AS THE DELTA SOURCE. Touches BASELINE PIN,
SELF-IDENTIFYING GENERATION, CHANGELOG.

**B. XDG scoping.** Decided: the framework-channel working state moves to XDG.
Undecided: does **all** plan working state (each downstream plan's `state.json` +
journal) also move to XDG, or does only the framework backlog move while ordinary
plans keep `<WORKTREE_ROOT>/.living-workflows/<plan>/`? Pick the XDG var by semantics
(mutable machine state → `XDG_STATE_HOME`; entries are working captures → same).
Touches STATE SUBSTRATE + `.gitignore`.

**C. Kiro skill-activation permission management via Nix (DEFERRED by operator).**
Needs hands-on exploration in a Kiro v3 environment. Question: should the Nix/HM
install also manage `permissions.yaml` (grant the `skill` capability + `fs_write` to
the XDG entries path) so the skill activates and can capture headless, or leave
permissions to the user? Do not decide from docs; explore when in a v3 env. Park as
NEEDS-EVIDENCE if it surfaces before then.

**D. Invocation handle.** NL / skill-description is the reliable cross-surface trigger
and the operator's stated preference. A custom slash is Claude-Code-only polish (not
documented on Kiro v3). If an explicit Kiro handle is wanted, the documented lever is a
user-level agent that attaches the skill via `skill://` (or a `Manual` hook), **not** a
slash. Likely no decision needed; recorded so it is not re-litigated.

**E. Changelog-to-web (unanswered).** The changelog is modify-time-only and inert in
web mode (no git, no pin, no reconcile). Does it have any web consumer (e.g., a web
tuning session reading convention history), or is it dead weight in the web payload?
Operator did not resolve; groomer decides or parks.

## Closed by this discussion (context for the groomer)

- Entry's "two flows" → actually **three** run-time entry points: create, resume (the
  most common; the entry omitted it), groom. The router selects.
- Entry's "co-locate all files deletes a defect class" → **resized**: 3 of 4 committed
  docs already share one dir; the only cross-`../` seam is the backlog-rules doc. The
  real win is the machinery-global vs instance-per-repo split (decision 1) plus the
  run-time/modify-time layering (decision 3) — not flat co-location. Co-location kills
  path-drift nits only, not enumeration/DRY-restatement nits (necessary-not-sufficient
  for the convergence / STRUCTURALLY-COLLAPSE goal).
- Distribution-intent gate (R-DIR-23's blocker) → **decided**: personal cross-surface
  (see "the why").
- Pin-substrate-breaks-under-distribution (the deep conflict raised earlier) →
  dissolved by "the why" (source repo always present) + versioning (decision 6 / item
  A).
- Entries cross-repo "which worktree root" fork → dissolved by XDG (decision 5).

## Discarded / considered-and-rejected

- **Hardcoded absolute entries path** — collides with "never hardcode the
  framework-channel location." Superseded by XDG.
- **Per-deployment ecosystem pointer for the framework channel** (the current master
  mechanism) — superseded by XDG for this deployment (a standard resolution beats a
  resolved-per-deployment pointer when one machine-global location suffices).
- **Raw-commit `living_doc_baseline` as the sole pin** — insufficient in web mode (no
  commit) and across surfaces; superseded by a version pin (item A) that resolves to a
  commit via derive-from-history.
- **Custom `/living-workflow` slash on Kiro** — not documented in v3; not the
  invocation handle. NL / skill-description is primary.
- **Positioning against / wrapping Kiro `/spec`** — dropped; "this is for me."

## Reference pointers

- Backlog item groomed: `living-workflow-backlog/entries/package-the-workflow-as-an-installable-skill.md`
  (operator-HOLD until this handoff).
- Master sections touched: STATE SUBSTRATE, ECOSYSTEM ADAPTER, DRY-BY-REFERENCE &
  BASELINE PIN, SELF-IDENTIFYING GENERATION, CHANGELOG AS THE DELTA SOURCE, REFLECTION
  MODE.
- Kiro v3 facts: `docs/plans/kiro-v3-docs.txt` (skills, permissions / `skill`
  capability, hooks, agent-config, specs, v2→v3 status).
