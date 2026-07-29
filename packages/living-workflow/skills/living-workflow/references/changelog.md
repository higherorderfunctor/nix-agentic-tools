# Living-workflow changelog — the judgment-based migration guide for dependents

This is the **migration guide** a DRY dependent reads to update itself when the living workflow's
conventions change. It **lives beside the master doc + shared harness** so the reconcilable unit —
protocol + harness + guide — travels together, and it is **scoped to MASTER protocol +
shared-harness changes only**: the backlog sub-workflow's own rules have no external dependent
(nothing pins to them; they are re-read fresh each session), so their changes are
**git-history-only** and are not added here (the retained backlog-sub-workflow subsection below is
pre-scoping provenance, not an ongoing record). It is **load-bearing ONLY when updating** — a normal
run never reads it, and nothing a run needs lives here. It is **judgment-based, not a mechanical
diff**: a **migration entry** is written ONLY when a re-syncing dependent must actually DO something
differently, and it says what an **upgrader** must change — grooming-internal conventions and
cosmetic/reflow-only edits add none. It is **leak-safe and workflow-focused**: each entry states
what changed in the conventions and where it folded (master protocol or shared harness) — **no entry
ids, no tuning-source references, no session/project detail**. A dependent pins to an assigned
**VERSION** (see the master's BASELINE PIN); to reconcile it resolves version → commit by
**derive-from-history** and reads the migration entries between its pinned version and the current
one, then re-pins. (The purpose and update mechanics — the version pin, the version-bump step, the
reconciliation walk — are owned by the master's DRY-BY-REFERENCE section; this doc is just the
record. Earlier sections below use the prior term "batch" for what is now a migration entry.)

## First committed baseline

Conventions established at the first commit of this living workflow, relative to earlier ungroomed
drafts. A dependent authored against a pre-commit draft reconciles against these. This batch's
anchor is **derived from git history** (the commit that first added this section), not embedded
here — see the master's CHANGELOG AS THE DELTA SOURCE.

**Headline upgrades in this baseline** (scan before the detail):

- Location encodes durability; two operating modes (web-run / cli); plan lifecycle (plans are
  scaffolding — distilled then deleted, the backlog excepted).
- Reflection scope + authority (only the backlog edits the workflow, via grooming); two-channel
  backlog terminology; the changelog reframed as a co-located, master-scoped convention-delta.
- Sanctioned operator deviation shape (deferral + override); author coverage intensionally;
  three-state capability resolution (present / absent / operator-gated).
- Document-only in-doc state block + self-identifying generation marker; prerequisite-presence
  preflight before costly automated passes; framework-channel location anchored to the living
  workflow (cross-repo aware).
- Single canonical harness (the embedded WEB fallback copy removed); bounded fan-out work-queue;
  acceptance-gated session close (kickoff required but non-authoritative); changelog anchor derived
  from git history; opaque cross-reference tags removed; NEEDS-EVIDENCE park disposition;
  first-commit triage of a durable baseline; modify-time-vs-run-time negative arm (no-audience
  content).
- Convergence criterion: a review/grooming pass converges at no BLOCKING finding (a green verdict is
  legitimate, not a weak review); non-blocking consistency nits are serviced by a lighter fix path,
  not hunted to zero.
- Change-time discipline: verify against the source not a proxy; declare the repoint-vs-migration
  change class before acting; every disposition carries its structural reason; gate briefs declare
  fix-vs-report scope up front; self-deleting terminal close; commit-body conventions.

### Master protocol (`living-plan-bootstrap.md`)

- **Location encodes durability:** committed docs carry durable knowledge; per-worktree gitignored
  `<WORKTREE_ROOT>/.living-workflows/<plan>/` carries working state (state.json, WAL journal,
  entries). There is no rendered status board and no render step in the standing machinery — read
  state.json directly.
- **Two operating modes**, resolved at cold start and recorded in `ecosystem.execution_mode`:
  web-run (no-repo/document-only, everything in the single doc, leak-safety relaxed) and cli
  (repo-backed, single machine, working state gitignored). Operating mode is a confirmed input,
  asked if unstated.
- **Web→CLI transition** redrafts the doc to CLI conventions and scrubs it clean — a hard gate
  before the first commit (the one place leak-safety is enforced by a stop, not a default).
- **Plan lifecycle:** a plan is development-time scaffolding — it completes, its durable knowledge
  is distilled into self-contained artifacts (plus an optional arch doc), then it is deleted and
  never merged; the perpetual backlog sub-workflow is the exception. The founding "git history is
  the project history" premise is thereby qualified to WORKING history — the durable project record
  is the distilled artifacts, not the deleted plan's commit trail.
- **Modify-time vs run-time context:** run needs are self-contained in the artifact; modify-time
  context (a completed plan's arch doc, the changelog) is referenced with a load-only-when-modifying
  marker and never on the run path. Arch doc is the exception (default self-contained; extract a
  co-located arch doc only when inlining would dilute run-time use).
- **Reflection scope + authority:** reflection captures improvements to the living workflow itself
  (from friction or generalizable steering), never a plan's own project content; no plan may edit
  the living workflow; every plan submits candidates to the living-workflow-backlog, the sole
  authorized editor via grooming. Grooming folds (its main work) and also reflects at its end,
  capturing new candidates as pending backlog items for the next pass, never self-grooming them.
- **Backlog terminology (two channels):** a plan's own `open_items` (plan-local) vs the
  living-workflow-backlog (framework); never cross them.
- **Changelog** is the convention-delta a dependent reads to reconcile — load-bearing only when
  updating, its batch anchors derived from git history, leak-safe, workflow-focused.
- **Baseline pin is active:** on start a dependent compares its pin to the current doc commit and
  reconciles via the changelog deltas before re-pinning; the living doc stays self-contained (no
  named source material).
- **New-plan location** resolved from repo context or repo-level steering; ask the human only if
  unresolvable. Plan naming: name a backlog plan after its seed workflow, and a plan's index doc
  after the plan.
- **Ecosystem adapter** resolves host execution/resource constraints + their safe workaround recipe
  into `ecosystem.execution_constraints` at cold start; commit-metadata conventions are
  per-repo/per-tool, resolved for the target repo, never carried across repos.
- **"Verbatim" under a formatter hook** means semantically-verbatim, never byte-identical; never
  assert byte-identity of committed embeds.
- **Cold start** derives a complete initial-state seed from the plan's own sections (no frozen
  duplicate block).
- **Greedy scheduler:** a phase's runnable increment must run on the actual shipping delivery path,
  not a proxy harness.
- **Decision-scope filter:** escalate only high-impact / intent-dependent / low-confidence calls;
  artifact-internal calls are agent-owned; no bonus questions.
- **Standing rule — source-masking:** fix the declarative source and re-derive with zero manual
  steps; never hand-patch live runtime (part of the "prove against reality" family).
- **Git workflow:** commit subject leads with a lowercase verb (work id in the body); commit often;
  sync with remote before push on shared branches, never force over divergent commits; verify
  committable status before writing into a gitignored-but-tracked subtree.
- **Validation-on-update:** verify referential integrity (targets resolve to a real primary), not
  just per-item well-formedness; trust no clean negative (no-ignore search in ignored-but-tracked
  trees; word-boundary match when excluding a substring token; cross-check negatives against
  known-present content). Session-close validation when updates were made: internal consistency +
  DRY-sync of dependent docs against the master.
- **Session bootstrap:** ground opaque/third-party assumptions in the exact artifact in play before
  iterating; exhaust every mechanizable unknown before consuming a scarce human/interactive gate; a
  subagent's deliverable must be in its final return message and subagent-supplied facts are
  verified against source. The plan itself is the cross-session handoff; re-confirm deliverable
  shape when the consumer changes.
- **Two-register communication:** dense handoff vs single-pass chat; pair labels with meaning; the
  dial is parse-cost, not depth.
- **Standing rule — sanctioned operator deviation from a binding rule has a defined, logged
  shape:** two recorded forms, never a bare "proceed" — DEFERRAL (log it and leave the step
  not-done with the position resting on it so the next session reopens AT it; deferred ≠
  skipped and does not weaken binding; a deferred hard gate also defers the action it gates)
  and OVERRIDE (a narrowed, provenance-logged gated reframe, not a blanket bypass).
- **Validation-on-update — author coverage intensionally:** a coverage/binding/validation
  rule states its scope by property ("every X, wherever recorded"), never as an enumerated
  section list that silently rots as an append-only doc grows.
- **Ecosystem adapter — three capability resolution states:** present / absent (with
  fallback) / operator-gated (exists but only the human can enable it — surface the toggle
  instead of silently degrading to the fallback).
- **State substrate (document-only mode) — designated in-doc state block:** where there is
  no state file, the machine-owned fields live in one designated in-doc block carrying the
  field shape the STATE SUBSTRATE prose enumerates (not scattered prose tokens, and no embedded
  schema to mirror), so state-over-tokens holds without a state file and the web→CLI redraft is a
  mechanical extraction rather than a re-derivation.
- **Web/no-repo mode — self-identifying generation (concrete shape):** the live doc carries a
  concrete two-key marker — a monotonic generation counter + a supersedes pointer (no separate
  deprecated flag; a non-highest copy is superseded by definition); cold start picks the highest
  and treats lower copies as superseded, so re-emitting the whole doc each session cannot silently
  resume a stale copy. Document-only only; the marker retires at the web→CLI transition.
- **Session bootstrap — prerequisite-presence preflight:** the fail-fast-before-a-scarce-gate
  discipline extends to costly/high-fan-out automated passes — record prerequisites as
  tracked state and verify their presence at the boundary before firing the pass (a missing
  input is a cheap STOP, not a post-pass failure).
- **State substrate / reflection capture — framework-channel location:** the framework channel
  (where reflection candidates land) is anchored to where the LIVING WORKFLOW itself lives —
  resolved at cold start into the ecosystem pointer, never hardcoded — so a session reflecting
  while running a plan in a different repo reaches the single canonical backlog; a plan's own
  working state still resolves to its own worktree.
- **Changelog — co-located with the master, master-scoped:** the convention-delta changelog lives
  beside the master doc + shared harness (the reconcilable unit travels together) and records
  master/harness convention changes only; the backlog sub-workflow's own rules have no external
  dependent, so their changes are git-history-only, not changelog deltas.
- **Session bootstrap — the root does not idle during a dispatch:** where the host permits
  progress while a dispatch is in flight, the root advances work whose inputs do not intersect the
  dispatch's outputs and whose outputs do not intersect its inputs; that intersection test IS
  independence, not a judgment call — but independence is necessary, not sufficient. The licence
  covers only non-interactive work the root's current position already permits: every standing
  gate and position rule keeps governing unchanged, wherever recorded, and a human/interactive
  gate is neither opened nor crossed to fill a wait. Never manufacture work to fill a wait.
- **Ecosystem adapter — new named capability:** `concurrent-progress-during-dispatch` joins the
  generically-named capability set resolved at cold start; where it does not resolve to available,
  the root simply blocks. A capability may now resolve to a host property rather than an action.
- **Validation-on-update — location is an implicit operand:** every relative reference resolves
  against the location of the artifact containing it, so relocating an artifact silently rewrites
  what its own internal relative references mean even though none were edited — and the ripple
  rule's grep, which quantifies over surfaces referencing the _changed thing_, structurally cannot
  surface them. On any location change, re-resolve every relative reference the artifact contains
  from its new location; still-resolving is not enough, since it may now resolve to the wrong
  artifact or by a detour.
- **Scaffold harness — single canonical copy, referenced not embedded:** the harness
  (`state.schema.json`) is the one canonical file beside the master; the demoted verbatim
  WEB/no-repo fallback copy is removed, along with the plan-structure "verbatim scaffold section"
  component. Document-only mode sources its state-field shape from the STATE SUBSTRATE prose and the
  IN-DOC STATE BLOCK, not an embedded schema.
- **Backlog-entry lifecycle — NEEDS-EVIDENCE park:** the disposition set gains
  `NEEDS-EVIDENCE:<what-would-decide-it>`, a HOLD (not terminal) for a candidate that is plausible
  but not yet decidable; the authoritative disposition set lives once in the shared-harness schema
  and is referenced by the entry contract rather than re-enumerated in prose.
- **Session bootstrap — bounded fan-out:** a wide parallel dispatch runs under a concurrency cap
  with excess drained through a bounded work-queue (pointers not payload; a dropped item is a
  surfaced failure, never a silent truncation); the cap is the safe-workaround recipe for a
  per-worker resource ceiling resolved as an execution_constraint.
- **Nesting pointer — key rename:** the `parent` object's `backlog_path` is renamed `parent_path`
  and the orphaned `backlog_entry` key is dropped (fossils of the retired adoption-child model),
  matching the field's project-nesting description.
- **Ecosystem adapter — absent is a falsifiable negative:** an absent capability resolution records
  the probe that produced it alongside the fallback, since a negative is never exercised and a
  mis-resolution is otherwise authoritative-by-construction; a present resolution is self-proving on
  use and needs no probe. Resolved-once stays intact but becomes falsifiable.
- **State substrate / cold start — entries/ scoped to the framework-channel host:** the `entries/`
  capture subdir is materialized only in the working dir of the plan that hosts the framework
  channel; an ordinary plan's working dir holds state.json + the WAL journal, tracks its own work in
  open_items, and routes reflection to the framework-channel location.
- **Reflection mode — steering at close is capture, not a licence to fold:** operator steering
  handed over at close is reflection INPUT (captured as entries, groomed later), explicitly closing
  the "mechanical vs reasoning" difficulty-split rationalization; acting is out of scope unless the
  operator directs immediate action.
- **Modify-time vs run-time — negative arm:** content with neither a run nor a modify audience does
  not belong; the canonical case is an imagined future (a clause about what might happen someday
  under a condition not yet met), which reads as settled policy and constrains fresh decisions;
  genuinely-needed deferred/rejected design keeps its modify-time home.
- **Plan lifecycle — first-commit triage of a durable baseline:** a durable-baseline artifact's
  first commit is the one cheap moment to triage accumulated working context (a gate distinct from
  the leak-safety scrub), sorting by modify-time-vs-run-time audience — keep run-needs and
  editor-needed rationale/rejected paths, drop provenance-for-its-own-sake.
- **Session bootstrap — acceptance-gated session close:** close fires on an explicit stop
  instruction or "no un-gated work remains", is offered (not presumed) via an acceptance gate that
  presents results + remaining agenda, and — only on acceptance — runs the close ritual, THEN
  produces the kickoff, THEN reflects. The kickoff is a required output of the gate but stays
  non-authoritative (the plan is the handoff; docs win). A session-ending wait is now distinguished
  from a mid-work HITL pause by this gate.
- **Self-identifying generation — concrete two-key shape:** the document-only generation marker is
  fixed to a concrete shape (a monotonic generation counter + a supersedes pointer; no deprecated
  flag — a non-highest copy is superseded by definition), document-only and retiring at the web→CLI
  transition.
- **Opaque cross-reference tags removed:** the short letter+number feature tags are deleted from the
  master protocol and the shared-harness schema descriptions; every internal cross-reference now
  names its target section/concept directly, and a reference-by-name (not opaque label) discipline
  is added under validation-on-update.
- **Changelog anchoring — derived from git history:** a changelog batch is no longer self-stamped
  with its own landing commit; the anchor is derived from git history at reconcile time (batch
  granularity, never per-line blame under a reflowing formatter), dissolving the self-reference. The
  dependent baseline pin (`living_doc_baseline`) stays embed-and-stamped; document-only mode has no
  commit anchor.
- **Validation-on-update — convergence, a green verdict is a real verdict:** a review or grooming pass
  converges at **no BLOCKING finding**, not at zero findings; blocking = wrong-instruction /
  self-contradiction / unexecutable-path / leak-or-self-containment breach / a real gap (incompleteness
  or regression, per degradation-by-shrug), non-blocking = consistency / context-budget / wording
  polish. "Commit-worthy" with non-blocking findings outstanding is a legitimate mature verdict (not a
  weak review); correctness and completeness are always blocking and always stop a first-baseline
  commit. Non-blocking findings are recorded and serviced, not hunted to zero — their supply is
  unbounded whenever the surface area is — and do not gate convergence.
- **Validation-on-update — verify against the source, not a proxy:** a carried tally is a
  lower-bound pointer (re-enumerate from source, never a stored count as a total); a
  substring/consistency scan matches on markup-STRIPPED content and classifies a formatting-only
  non-match as benign-non-survival vs a real miss; a bulk token/key replacement is word-boundary,
  longest-token-first, with a post-replace corruption scan distinct from the coverage grep — the
  positive-count and content-match duals of trust-no-clean-negative.
- **Validation-on-update — declare the change class before acting (repoint vs migration):** a
  behavior-neutral reference repoint and a behavior-affecting output migration are separate change
  classes with separate authorization; a migration cannot ride a repoint's grant, and the class is
  stated before acting.
- **Open-items register — every disposition carries its structural reason:** a register entry
  records WHY it holds its disposition (the structural reason, not just timing/order), stated as a
  property over every entry rather than an enumeration of the dispositions that currently force a
  reason.
- **Open-items register — gate-brief scope declared up front:** a validation/gated-review brief
  states before it runs whether in-scope blockers are fix-in-session or report-only (fix only when
  behavior-neutral AND agent-owned), settled at brief time rather than adjudicated mid-run.
- **Plan lifecycle — self-deleting terminal close:** when a plan's terminal action removes its own
  state substrate, the close ritual's mutate/validate steps have nothing to operate on; the durable
  record redirects to the surviving settled artifact's changelog + commit message + git history, and
  the settled-doc update lands atomically with the deletion.
- **Git workflow — commit-body conventions:** respect the repo's commit-BODY line-length rule (wrap
  the body; prefer a message file for multi-paragraph messages), resolved per-repo off the
  commit-metadata capability, never a hardcoded width.

### Backlog sub-workflow (`living-workflow-backlog.md`)

> **Sub-workflow-internal — NOT dependent-facing.** Retained for provenance. Per the
> master-scoping decision, changes to this sub-workflow's own rules are dependent-irrelevant
> (nothing pins to them), so future such changes are recorded in git history only, not here.

- **Working state** (state.json, journal, entries) lives in gitignored `.living-workflows/`;
  committed surface is the index doc (the changelog is master-owned — see intro). No status file.
- **The grooming loop** (deterministic): cold-start reconcile → per-entry adversarial eval
  (positive criteria + confidence signal + orchestrator re-derivation) → classify fold target →
  decision-scope present → inline fold + drain → persist each disposition. Grooming's goal is to
  FOLD; GROOMED is transient; folding removes the entry (fold = drain).
- **This doc is the FRAMEWORK channel**, distinct from a plan's own `open_items`.
- **Capture/grooming split:** files authoritative for pending capture; grooming owns the register;
  the folded tuning + changelog line is the durable record.
- **Soft git posture:** working state gitignored/never-committed; scrub on the way in; defer the
  commit when unsure; no automated gate.
- **Register + changelog:** the register is bounded to active candidates; a fold tuning
  master/harness conventions appends a convention-delta line to the co-located changelog; a fold
  tuning only these backlog rules is
  git-history-only; a drop is recorded in the working journal only (it changed no convention).

## Capability sourcing + workflow change-channel

Convention deltas folded after the first committed baseline. This batch's anchor is **derived from
git history** (the commit that first added this section header), not embedded here.

### Master protocol (`living-plan-bootstrap.md`)

- **Reflection scope + authority — sole editor implies sole change-channel:** the same authority that
  makes the living-workflow-backlog the only editor of the workflow also fixes the only ROUTE a
  workflow change may travel — every change enters through a sanctioned change-channel (a
  groomed-and-folded backlog entry, or the lighter fix path for a mechanical behavior-neutral nit) and
  the backlog's own state substrate IS the plan-of-record; a workflow change is never planned or
  staged off-substrate (scratch file, external planning doc, task-tracker), and reaching for such a
  side channel is itself the tripwire to route it through the backlog instead. Scoped to changes to
  the workflow itself; a downstream plan's own scratch space is untouched.
- **Ecosystem adapter — prefer a reproducible source for a present binding:** when a capability can
  bind either to a primitive from the project's declared reproducible toolchain or to a host-PATH
  binary, bind the project-provided one and mark any host-only binary as a flagged fallback; a
  toolchain-sourced primitive resolves identically on every independent cold start (portable,
  deterministic) while a host-only binary is self-proving only within its machine — so the
  self-proving-on-use property is scoped to a single machine and cross-machine determinism comes from
  sourcing the primitive reproducibly.

## Versioning

Migration entries folded after the capability-sourcing batch. This section's anchor is **derived
from history** (the commit that assigned the master version `v3-cedar-harbor-quartz`), not embedded
here.

### Master protocol (`living-plan-bootstrap.md`) + shared harness (`state.schema.json`)

- **Baseline pin — an assigned VERSION, not a raw commit.** A dependent's `living_doc_baseline` now
  records the master's assigned VERSION (a monotonic ORDINAL for "am I behind" + a DISTINCTIVE LABEL
  so the exact version stays searchable), not a git commit hash. **To reconcile: re-pin your
  `living_doc_baseline` from the old `commit` field to a `version` field** (schema: `required` is now
  `[path, version]`; `commit` is removed). A version is content the doc assigns itself — not a
  self-named commit hash (which cannot be written into the commit that creates it) and not a
  build-tool-injected identity (e.g. a Nix flake's `self.rev`, which cannot see a dirty tree, is
  whole-repo-granular, and never reaches web) — so it resolves to a commit by
  **derive-from-history** (the commit that assigned it; assignment granularity, never per-line blame
  under a reflowing formatter) and also travels to a document-only artifact that has no commit. A
  version read off a dirty/uncommitted master is **provisional-until-committed** — carry
  `PENDING-RESIDENT-STAMP`, never the provisional value.
- **Active drift reconciliation is version-based:** compare your pinned VERSION to the current one;
  if it moved, read the migration entries between them (resolving version → commit to bound the range
  when a repo is present) and re-pin to the new version.
- **Changelog is now a judgment-based migration guide:** an entry is written only when a re-syncing
  dependent must do something differently; the VERSION is the reconcile ENTRY POINT, entry headers
  stay DESCRIPTIVE, and reconcile correctness rests on guide COMPLETENESS (a real change committed
  without its entry is silently missed) — so the version bump and the entry are authored TOGETHER in
  the same modifying commit (the VERSION-BUMP STEP, a judgment step, not a hook).
- **Mode-history ledger (shared harness):** the `ecosystem` record gains an optional
  `execution_mode_history` array — an ordered ledger of the web/cli segments a plan has run in (a plan
  may cross the boundary more than once); the single `execution_mode` remains the current mode. No
  dependent action required (additive/optional).
- **Self-identifying generation marker clarified:** the document-only web generation marker is
  DISTINCT from the committed master VERSION — different docs, different lifetimes; the marker still
  retires at the web→CLI transition. No dependent action required.

## Session-close operator experience

Migration entries folded after the versioning batch. This section's anchor is **derived from
history** (the commit that first added this section header), not embedded here.

### Master protocol (`living-plan-bootstrap.md`)

- **Session bootstrap — full open-items register at the opener:** the session opener (step 4) now
  ALSO presents the plan's whole `open_items` register at a HIGH level (every active/held/parked item
  as one-line headers — a read-only visibility snapshot, not a question batch), so an operator
  running consecutive sessions sees where newly-captured and held items sit. **Upgraders: add the
  opener-side full-register snapshot** (the close already presents the register; it is now marked
  high-level).
- **Session close — approve the next-session direction in chat before the kickoff:** the close
  acceptance gate's PRESENT-then-ask now widens (ii) to a PROPOSED next-session plan (each candidate
  focus carrying enough context for an informed pick, never a bare label) and (iii) to an ask the
  operator can APPROVE / WEIGH IN / RESHUFFLE — and the approved direction is CAPTURED before the
  close ritual's state mutation, so the recorded next position and the (non-authoritative) kickoff
  both encode the approved plan. Rationale: the operator does not read the dense AI-facing kickoff.
  **Upgraders: widen the close gate's ask to approve/reshuffle the next-session direction and capture
  it before state mutation.**
- **Session close — copyable kickoff prompt in web:** in WEB mode, where the host renders a copy
  affordance on fenced code blocks, a prompt the operator copies verbatim into a fresh session (the
  kickoff, or a proposed next-session prompt) is emitted inside a FENCED CODE BLOCK rather than a
  blockquote, for one-click relaunch. Web-only; moot in CLI. **Upgraders: emit copyable prompts as
  code blocks in web mode.**

## Entry hygiene + terminology

Migration entries folded after the session-close-operator-experience batch. This section's anchor is
**derived from history** (the commit that first added this section header), not embedded here.

### Master protocol (`living-plan-bootstrap.md`)

- **Backlog-entry contract — an entry describes the ISSUE, not a solution:** the master's
  NON-prescriptive clause now states an entry CHARACTERIZES the problem (the friction, its mechanism,
  its evidence) and leaves the fix to grooming — a groomed candidate, not an applied change AND not a
  prescribed solution (noting a candidate direction as explicitly-undecided context stays allowed;
  prescribing a chosen lever is the anti-pattern). **Upgraders: hold pending captures to an
  issue-first shape — reframe any that prescribe a chosen fix to describe the friction instead.**
- **Terminology — "buffer" renamed to "capture" / "pending backlog items":** the reflection/capture
  vocabulary drops the word "buffer" — a reflecting session now CAPTURES new candidates as pending
  backlog items, and the "buffer-not-self-groom" rule is now "capture-not-self-groom". A
  behavior-neutral rename with no mechanism change. **No dependent action required** (update local
  wording only if you quote the old term).

## XDG state relocation

Migration entries folded after the entry-hygiene batch. This section's anchor is **derived from
history** (the commit that bumped the master to `v6-garnet-tundra-birch`), not embedded here.

### Master protocol (`living-plan-bootstrap.md`) + shared harness (`state.schema.json`)

- **State substrate — working state now lives OUT-OF-REPO under an XDG base:** CLI working state
  (state.json + the WAL journal, and the framework channel's entries/) no longer lives in the in-repo
  `<WORKTREE_ROOT>/.living-workflows/<plan>/`. It resolves to
  `<xdg-state-base>/<clone-name>/<workflow-name>/`, where `<xdg-state-base>` is the installed skill's
  baked `$XDG_STATE_HOME/living-workflows` (default `~/.local/state/living-workflows`), `<clone-name>`
  is the basename of the main clone's directory (git's common-dir parent —
  `basename "$(dirname "$(realpath "$(git rev-parse --git-common-dir)")")"`, falling back to the
  current directory's name if git is unavailable), and `<workflow-name>` disambiguates workflows in
  one clone. **Upgraders MUST migrate existing state:** move any in-repo
  `.living-workflows/<plan>/` working dir to the new XDG location by a tested move (copy → prove
  resume → remove old); nothing writes to the in-repo `.living-workflows/` any more.
- **git-common-dir inverts from forbidden to the namespace KEY:** the retired rule resolved a plan's
  location via `git rev-parse --show-toplevel` and forbade the shared common git dir. The new rule
  USES the common git dir — its parent's basename is the clone namespace KEY (not the location) — so
  state is CLONE-scoped: it survives worktree teardown and is shared across every worktree of one
  clone running the same-named workflow. **Upgraders: adopt the git-common-dir key; do not resurrect
  the show-toplevel / per-worktree location rule.**
- **Framework-channel location — pointer dropped; the backlog is a first-party override:** the
  framework channel (the living-workflow-backlog's entries/) is NOT repo-bound — it pairs with the
  installed skill and DROPS the clone segment, resolving to the single machine-global
  `<xdg-state-base>/living-workflow-backlog/` regardless of which repo you reflect from, so all
  living-workflow feedback lands in the ONE canonical backlog and the cross-repo "which worktree
  root" fork dissolves (no foreign worktree, no cold-start pointer). **Upgraders: drop the
  framework-channel ecosystem pointer; resolve the backlog to
  `<xdg-state-base>/living-workflow-backlog/` (no clone segment).**
- **Leak-safety improves; `.gitignore` kept as belt-and-suspenders:** working state living outside
  every repo cannot be committed by accident (a strict improvement over gitignore-by-location). The
  repo's `.living-workflows/` gitignore line is retained only as cheap safety against a stray in-repo
  write. No dependent action beyond the state migration above.
- **Shared harness (`state.schema.json`) — descriptions only:** the `execution_mode` and
  `living_doc_baseline` descriptions now name the XDG location and the installed-skill path resolution
  (a running plan reads the master from the installed skill's `references/`; version→commit
  reconciliation resolves against the nix-agentic-tools source checkout). No field-shape change, so
  **no dependent action required** beyond the state migration above.

## Version-bump boundary + design-phase coherence

Migration entries folded in the pass that bumped the master to `v7-slate-marsh-aspen`. This section's
anchor is **derived from history** (the commit that assigned that version), not embedded here.

### Master protocol (`living-plan-bootstrap.md`)

- **Version bump gated on behavior-change, reconciled with the fix path:** the VERSION-BUMP STEP now
  states the bump criterion as the BEHAVIOR-NEUTRAL versus BEHAVIOR-CHANGING line (the same
  REPOINT-VS-MIGRATION change class), independent of the migration-entry decision. Only a
  behavior-changing edit (one that changes what some instruction directs a reader to do) bumps and
  authors an entry; every behavior-neutral master edit — cosmetic, reflow, a deliberate terminology
  rename, or a light-fix repair alike — is git-history-only, bumping nothing and adding no entry.
  **Upgraders maintaining bump discipline: do not bump the version or write a migration entry for a
  behavior-neutral master edit (including a deliberate rename); record the surface change in the
  commit message and git history. The light-fix path is not a special exemption — it is this same
  boundary applied by a different actor.**
- **Design-phase coherence review:** a plan that separates a design phase from a build phase now
  closes the design phase on its OWN adversarial coherence/contradiction review; self-contradiction
  found there is a blocking finding by the convergence criterion, not deferred to the build-diff
  review. **Upgraders: for design/build-separated plans, add a design-coherence review at design
  close rather than relying on the build-diff review to surface design-internal conflicts.**

## Co-occupied commit vehicle + continue-past deferral + coverage-check before capture

Migration entries folded in the pass that bumped the master to `v8-onyx-moor-rowan`. This section's
anchor is **derived from history** (the commit that assigned that version), not embedded here. All
three are behavior-changing master edits.

### Master protocol (`living-plan-bootstrap.md`)

- **Co-occupied working tree — a third commit-ownership condition:** COMMIT-OWNERSHIP now names a
  case beyond we-commit / resident-commits: when the target working tree is CONCURRENTLY OCCUPIED by
  another writer (a second session editing the same checkout), neither mode fits — a direct
  we-commit risks capturing the other's uncommitted work, and no single resident will commit THIS
  session's work. Resolve co-occupancy to an isolation-plus-integration vehicle (an isolated worktree
  branched from the live tip, committed there, integrated by an open PR/MR), never a write to the
  shared tree. **Upgraders: if you resolve commit_ownership in a repo whose working tree is
  co-occupied by another live session, do not we-commit into the shared tree and do not leave it
  dirty for a resident — branch an isolated worktree and integrate by PR/MR; use the plain we-commit
  path only when the tree is exclusively yours.**
- **Continue-past variant of the DEFERRAL shape:** SANCTIONED OPERATOR DEVIATION's DEFERRAL now
  covers an operator deferring a gate only THEY can fire (a live-environment verification, an
  external sign-off) while directing work to continue past it. The owed gate moves OFF the position
  pointer and INTO the register as its own item, and phase-done SPLITS into session-provable (every
  mechanized gate passes) versus operator-verified (the deferred gate fires); the owed verification
  may batch across phases. This applies only when deferring the gate blocks nothing mechanical.
  **Upgraders: when an operator defers an operator-only gate but directs work onward, do not rest the
  pointer on the gate — record the owed gate as a register item and mark downstream phases
  session-provable, not operator-verified, until it fires.**
- **Coverage-check before capture (reflection inflow gate):** REFLECTION MODE now requires a
  reflecting session, before filing a framework candidate, to check whether an existing named rule
  family already addresses the friction. A covered instance is NOT filed as a new rule — the session
  writes only an entry FILE (never the register): it appends a sighting to the existing entry file
  that holds the friction, or files an enforcement/coverage-gap candidate when the rule is sound but
  under-applied; grooming reconciles the sighting onto its register-resident entry. It is the
  capture-side dual of grooming dropping a candidate an existing rule already covers. **Upgraders: at
  reflection/capture, run the coverage-check before filing — do not file a fresh tuning candidate for
  a friction an existing rule already covers; append a sighting to the existing entry file or file it
  as an enforcement-gap instead, never writing the register.**

## Dispatch contracts + phase exit criterion + state-write integrity

Migration entries folded in the pass that bumped the master to `v9-basalt-fenland-hazel`. This
section's anchor is **derived from history** (the commit that assigned that version), not embedded
here. All are behavior-changing master edits.

### Master protocol (`living-plan-bootstrap.md`)

- **Every phase states its DONE-CONDITION:** the GREEDY SCHEDULER now requires each phase to state
  what must be TRUE for it to be finished, not only what it must produce. With that slot empty the
  open-items register drifts into the completion criterion by default, and "done" becomes "the
  register is empty" — unsatisfiable by construction, because the register grows with discovery and
  discovery scales with carefulness, so carefulness pushes the off-ramp away. **Upgraders: write a
  done-condition for every phase that does not have one, including phases already in flight —
  evaluating them is cheap and may show a phase is already complete. Record it in state as
  `phases[].done_condition` (see the shared-harness section below), not as plan prose alone, and
  BACKFILL the field for existing phases when you re-pin. Do not write a condition that
  verifies against an upstream source the work itself absorbs or deletes; over an absorption or
  migration target, state the condition against what SURVIVES the work, or it becomes unsatisfiable
  exactly by succeeding.**
- **Fix-on-contact — the timing arm of the DECISION-SCOPE FILTER:** the filter allocated OWNERSHIP
  of a call but said nothing about TIMING, so the conservative reading (record it for later) won by
  default and inflated the register with items whose fix costs less than the bookkeeping about
  them. A defect met while working elsewhere is now FIXED ON CONTACT when four bounds hold: in
  scope already being touched; agent-owned by the filter; provable by controls already running; and
  it does not widen the change beyond ONE REVIEWABLE UNIT. **Upgraders: stop routing agent-owned
  trivia into the register by default. Apply the fourth bound in both directions — carve out an
  adjacent defect that would widen the diff along an unrelated axis, and decline any fix nothing
  available can verify, however small. This is a timing default only; it is NOT an intake filter
  deciding what gates a phase, and it does NOT override a standing authority or change-channel
  rule — a defect in a surface another authority owns (notably the living workflow itself) still
  routes through that channel however small, and fix-on-contact never licenses a behavior-CHANGING
  edit that would owe a version bump, nor an edit a binding rule bars. Where a gated-review brief
  has DECLARED its fix-versus-report handling, that declaration governs its own findings.**
- **Step 6 restructured into four dispatch contracts (brief / return / bounds / wait):** the
  subagent step now separates what goes out, what comes back, how wide a dispatch may run, and what
  the root does while waiting.
  - _Brief contract:_ a brief's INSTRUCTION content is authoritative; its DESCRIPTIVE content is a
    secondhand account and is NOT authoritative over what the worker observes. **Upgraders: mark
    which is which in every brief; state the factual half as carried context the worker must
    re-ground; add divergence reporting in BOTH directions as a named deliverable slot; supply a
    SHAPE rather than ready-to-paste syntax for any context you have not exercised; carry the
    DECISION a measurement feeds alongside the question; state rules by property, not by the one
    instance you noticed; and grant standing permission to widen a scope drawn too narrowly.
    Reviewing a brief harder does not catch these — exercising it does.**
  - _Return contract:_ the duty to verify a worker's return widens from facts/anchors/citations to
    EVERYTHING a worker returns, as one property rather than an enumeration. **Upgraders: treat a
    worker's JUDGMENTS (notably the severity it assigns its own disclosed limitation), CORRECTIONS
    to your stated facts, and COMPLIANCE claims about where it put an artifact as claims under
    test, not as already assessed. Verification MAY now be delegated, but only if the verifier's
    brief frames the worker's output as claims-under-test rather than context, and only if you read
    PER-CLAIM verdicts rather than a rollup. Note the anti-reading: cheaper verification finds
    MORE, so it makes a plan correct, not convergent — it pulls against the phase exit criterion.**
  - _Dispatch bounds:_ the fan-out ceiling is restated in the RESOURCE that actually binds
    (per-worker cost against a host budget that concurrent non-dispatch load also consumes) rather
    than a bare count of in-flight workers, and must COMPOSE. **Upgraders: a count-legal dispatch
    can still exhaust the host; resolve `delegation-depth` as a generically-named capability at
    cold start (it joins the standard roster, so resolved records stay comparable across
    dependents) and, where nesting is
    permitted, apply the ceiling over TOTAL live workers rather than per level (N per level across
    two levels admits N², invisible to the root). Prefer fatter dispatches over more concurrent
    ones, and when estimating throughput count serialization points — a single-invocation
    verification step, or an integration vehicle admitting one reviewable unit at a time. Where the
    host budget does not resolve, fall back to a conservative in-flight count (order ~10) recorded
    as that constraint's flagged fallback; never leave a wide dispatch nominally unbounded.**
  - _Wait contract:_ the non-idle licence extends from a wait on the session's OWN dispatch to ANY
    wait, including on an external actor (reviewer, check queue, integrator). The independence
    test's OPERAND is now defined. **Upgraders: intersect the PROPAGATION CLOSURE of what a unit
    causes to change — including whatever an environment rule obliges to move with an edit, and
    every artifact regenerated from an edited source — not the artifacts its subject visibly
    occupies; computed over the visible set the test returns a confident clean negative over the
    wrong operand. Every standing gate still binds; a watcher armed to fill a wait must cover EVERY
    terminal state, not only success, or a loud failure inverts into an apparent ongoing wait; keep
    it non-blocking, disarm it on fire, and arm sequential waits separately.**
- **Declare a session's scope up front, and protect its purpose (step 7):** nothing bounded the
  TOTAL work a session took on — the soft-close reacts only after consumption is already high — so
  sessions accreted units until they degraded or were killed, dropping in-flight work. **Upgraders:
  declare each sitting's scope at session start as a WEIGHT with a size test (isolate large, group
  small and medium), never as a COUNT — a count is satisfied by one small item. Key the
  inline-versus-delegate call to protecting the declared purpose's context rather than to
  implementation volume: off-purpose mechanical side work is delegated however small it looks.**
- **State-write integrity (STATE SUBSTRATE):** the prescribed mutation idiom was
  destructive-by-construction — write-to-temp then atomically replace, with nothing validating
  between the halves, so a transform erroring mid-write annihilates good state. **Upgraders:
  validate the TEMP file (parses, satisfies the schema, holds expected invariants such as an
  element count) BEFORE the atomic replace; the validate step is part of the idiom, not optional
  discipline around it. Never hand-assemble a structured record — build it with a serializer and
  parse it back before it lands, since a malformed append is silent until a LATER session reads it.
  Feed payloads via a file or stdin rather than command arguments: state prose routinely quotes
  tool invocations as data, and a host guard scanning command text cannot tell a quoted example
  from a live invocation. The ban is scoped to SCHEMA-BACKED or machine-parsed records; free-form
  human narrative is exempt. Where this recurs and the property is mechanically decidable, build a
  write HELPER that makes the guard un-skippable rather than restating the rule in prose.**
- **Mutation mode follows what a field HOLDS, not which artifact it sits in:** append-only was
  previously a property of the ARTIFACT, which made appending the default for every field inside
  one — including fields holding a current rule. **Upgraders: a
  RECORD-bearing field (narrative, history, accrued sightings) is append-only; a RULE-bearing field
  (a current rule, disposition or convention) is REPLACED IN PLACE. Appending a correction to a
  rule-bearing field leaves it carrying its own contradiction, resolvable only by a
  newest-clause-wins convention nothing states, so superseded text keeps being read as live.**
- **An instruction-bearing artifact carries the authority of the context that AUTHORED it:** a
  relayed brief or design, or a self-contained skill invoked as the session's main work, arrives
  with working practices attached, and nothing said which governs. **Upgraders: where those
  conflict with a binding rule of the RECEIVING context, the receiving context's rules win, and the
  conflict is SURFACED, never silently resolved either way; adopting the foreign instruction
  re-enters through the recorded OVERRIDE form with the operator's authorization as provenance.
  Correct the reliable asymmetry — an artifact's technical claims get checked against the live
  system while its procedural claims are adopted uncritically.**
- **The isolation vehicle's LOCATION is constrained by a property:** CO-OCCUPIED WORKING TREE said
  only to bind a vehicle at resolve time, leaving its location free once working state moved
  out-of-repo. **Upgraders: place the vehicle INSIDE the host's dev-environment auto-activation and
  trust scope. Outside it, a vehicle contains none of the project's generated configuration while
  LOOKING fully set up (tooling is on PATH, inherited from the parent process) and fails at the
  first commit. State the property alongside any default you adopt, so a consumer who cannot use
  the default knows what to preserve. Derive the path from the clone's COMMON git directory — a
  naive relative form resolves one level too deep when run from an already-linked vehicle — and do
  not assume isolating a working tree isolates a shared hook directory or event database.**

### Shared harness (`state.schema.json`)

- **`phases[].done_condition` added (additive/optional):** the new per-phase exit criterion is
  schema-backed, matching the precedent of its `ordering_rationale` and `budget_estimate` siblings
  and honouring STATE-OVER-TOKENS — the criterion that decides phase closure now lives where the
  phase record lives, not only in plan prose. The field is OPTIONAL in the schema so plans authored
  before v9 stay schema-valid. **Upgraders: extend your harness copy with the field, then BACKFILL a
  done-condition for every phase in your plan's state, including phases already in flight. A missing
  `done_condition` no longer means "no exit criterion exists" — it means one is OWED.**

## Close-ritual preconditions + decision joins + durable-record authority

Migration entries folded in the pass that bumped the master to `v10-cobalt-scarp-alder`. This
section's anchor is **derived from history** (the commit that assigned that version), not embedded
here. All are behavior-changing master edits.

### Master protocol (`living-plan-bootstrap.md`)

- **The redirect-to-history assurance is FALSE for out-of-repo state (correction):** SELF-DELETING
  TERMINAL CLOSE justified deleting a plan's own substrate by saying the durable record redirects to
  the settled artifact and version-control history. That holds only for a COMMITTED substrate, and
  the master mandates two — working state lives outside any repository, so version control never saw
  it and the deletion is unrecoverable. **Upgraders: do not let a terminal close lean on that
  assurance for out-of-repo working state. Where a delete would remove it, RETAIN it with a
  terminal-fold marker and leave the deletion OWED via the recorded-DEFERRAL shape, for an
  operator-present session to perform. This matters most when the close runs unsupervised under a
  standing pre-authorization, where neither a human confirmation nor a VCS backstop is in play.**
- **Close ritual gains a PRECONDITION on in-flight signals:** acceptance and completion are
  different events wherever a unit leaves the session as a change only an integrator may land.
  **Upgraders: before running the ritual, every unit you delivered must have reached a TERMINAL
  state on every attached signal — the automated check pipeline AND any automated reviewer, which
  reports on its own schedule and is a SECOND signal, not part of the first. Watch them and ACT
  (fix failures, address findings) before handing back; a signal in flight is un-gated work
  remaining. This is CONDITIONAL — vacuous where the host has no integration vehicle — and does not
  deadlock the budget soft-close, and it has TWO EXITS so it can never hold a close open
  indefinitely: an explicit operator stop/close instruction fires the ritual regardless of what is in
  flight, and a signal that cannot be brought terminal within the sitting is not waited on (tell
  never-armed from in-flight by adjudicating on observable SIDE EFFECTS, never channel silence). On
  any exit the affected units reach SESSION-PROVABLE completion and flip done, and the owed landing
  is recorded as its own register item naming what it still gates — the CONTINUE-PAST VARIANT shape.
  Do NOT invent a new unit status; `units[].status` is unchanged.**
- **The close ritual is not atomic, and is ordered by REVERSIBILITY where interruption is possible:**
  it is not a WAL unit, so the reversible/side_effecting classing was never scoped to it. **Upgraders:
  treat its steps as riding distinct capability channels with unequal reversibility (state is
  rewritable, the handoff inert, an append-only capture the capturing session may not groom cannot be
  unwound). The irreversible step is the reflection capture (c) and it stays LAST, exactly as
  REFLECTION MODE already fixes it — the ordering duty is WITHIN the sequence, not a reordering of
  it: where interruption is a live risk, complete (a), the validated state write, before starting
  (b), so a half-run close leaves a re-verifiable residue. A close fired early or interrupted must be RETRACTED
  explicitly — reverse what is reversible, mark what is not, and record that a retraction occurred.**
- **Join the recorded decisions to the work stream, both directions:** the verification pipeline
  checks an artifact's CORRECTNESS and never its CONFORMANCE with what was already decided.
  **Upgraders: FORWARD — check every newly-minted or INHERITED item against the recorded decisions
  BEFORE building it; review depth amplifies this miss rather than catching it, because every
  reviewer inherits the same framing. BACKWARD — when contact with the real system falsifies a
  settled decision, fork by ownership (agent-owned: re-decide and re-record; operator-owned: pause
  and re-ask), and in both cases MARK the superseded decision superseded where it sits — that
  marking is the load-bearing half, since a superseded-but-unmarked decision reads exactly like a
  live one. If reconciling requires WIDENING the item, it must still land as one reviewable unit;
  otherwise record and re-scope rather than absorb.**
- **The durable record is the authority on what THIS session did:** **Upgraders: the WAL duty is
  stated per UNIT, so work that does not decompose into units (investigation, measurement, review
  rounds, corrections) fires no trigger and leaves a narrative indistinguishable from an unstarted
  session — write it anyway. Do NOT auto-derive narrative entries from state mutations. And answer
  authorship/presence/ABSENCE claims about your own work from the durable record, never from
  recollection: your visible history is a host artifact that may be truncated, summarized or
  restored with no gap marker. At close, assert the narrative carries an entry from this session and
  that the position marker was RE-DERIVED, not inherited.**
- **Present is self-proving only for what is actually EXERCISED:** **Upgraders: label a recorded
  FALLBACK, and any named SUB-IDENTITY the primitive must reach, as VERIFIED against the real target
  or merely OBSERVED PRESENT — neither is exercised in normal operation, so self-proving-on-use is
  affirmatively false for them, and they fail exactly when the primary already has. This adds a
  LABEL, not a probe: do not eagerly exercise fallbacks. The label rides inline in the existing
  freeform capabilities map; no harness change.**
- **A resolved binding may still fail at USE time:** **Upgraders: treat a use-time refusal as a
  transient condition, NOT as evidence the binding is wrong — do not re-resolve or thrash the
  capability; preserve durable partial progress and defer.**
- **Adjudicate a wait on observable SIDE EFFECTS, not channel silence:** **Upgraders: where a
  capability reports completion over a notification channel, do not treat that channel as infallible
  — silence is indistinguishable from legitimate long work, so a finished worker becomes an
  indefinite stall. Check the effect the work would have produced, and record the channel's known
  failure modes on the capability itself.**
- **An expired justification is a first-class finding:** the standing prohibitions each bar a removal
  that MASKS a failure; none bars one whose reason to exist has lapsed, but stated only as
  prohibitions they read as a one-way ratchet. **Upgraders: when ABSORBING or CARRYING FORWARD
  material, verify its justification still holds — that check is expected, and an expired
  justification is a finding to raise, log and decide. This licenses LOOKING, not dropping: every
  existing prohibition governs the removal itself unchanged.**

## Proof reach — assert the postcondition, across five dimensions

Migration entries folded in the pass that bumped the master to `v11-verdigris-tarn-linden`. This
section's anchor is **derived from history** (the commit that assigned that version), not embedded
here. All are behavior-changing master edits.

### Master protocol (`living-plan-bootstrap.md`)

- **New VALIDATION-ON-UPDATE rule — ASSERT THE POSTCONDITION, NOT THE INVOCATION:** the two existing
  verification rules there govern a result's EMPTINESS (TRUST NO CLEAN NEGATIVE) and its FIDELITY TO
  THE SOURCE (VERIFY AGAINST THE SOURCE); neither governs its REACH, and PROVE AGAINST REALITY bars
  green-against-a-proxy without naming any way to tell that a given green IS one. Both are
  unchanged; this is a third sibling beside them. **Upgraders: stop reading a verdict off the
  INVOCATION (it ran, it printed, it exited zero, the standing gate is green) and read it off the
  POSTCONDITION (the target was actually processed, a known-present control was actually found, the
  guarded branch actually executed). Both polarities fail silently — a false CLEAN from a swallowed
  error stream, an exit status read through a pipe or filter, an always-true or always-false
  condition over the real corpus, a cache satisfying the request above the code under test, or a
  call site hardened not to abort a batch (which therefore CANNOT report that a change to it was
  wrong, raising rather than lowering its verification bar); and a false POSITIVE from a
  recall-oriented net whose hits are candidates, promoted to a finding with no precision probe for
  the failure signature.**
- **The INSTRUMENT TEST is the concrete discharge, and it binds committed instruments too:**
  **Upgraders: before consuming any instrument's output as fact, exercise it where the answer is
  ALREADY KNOWN, in BOTH polarities — it must FIND a known-present control and MISS a known-absent
  one; where the instrument does not exist yet, enumerate the corpus BEFORE choosing the condition.
  This is not scoped to ad-hoc probes: a long-lived committed filter, a standing gate and a detector
  earn the same treatment, and being purpose-built earns an instrument no trust. Apply it hardest
  when WIDENING an existing check's scope, which converts an honest "we do not check there" into a
  load-bearing "we check there and it is clean" that nobody revisits — detection coverage and scope
  coverage are independent, and only scope is visible in a diff.**
- **Five named dimensions, each carrying its own CHECK:** **Upgraders: run each check, RECORD the
  uncovered delta where the work's own durable record lives, and either close it cheaply or LOG AN
  EXPLICIT ACCEPTANCE (the silent third option is already barred by degradation-by-shrug; a delta
  named only in passing is that option wearing a name). SCOPE — enumerate the surfaces a change ships
  on plus every authoritative artifact its dispositions will be read from, and subtract what your
  gate exercises; the shipping path is PLURAL. DEPTH — name the deepest operation the proof performs
  versus the deepest real use performs; a gate that evaluates but realizes only a subset leaves a
  covered surface unproven. INSTANCE — list what varies per instance across a fan-out and treat
  every unsampled instance as unproven on those; sampling proves the shared MECHANISM only, and the
  runnable-increment constraint is fully satisfied by an under-covering proof. DURATION — record a
  result's moment and scope and what would RETIRE it, and re-establish it at point of use; a sample
  licenses an ABORT, never a PROCEED, and a stale ASSERTION can INVERT where a stale COUNT merely
  under-reports — but prescribing a value stays CORRECT where deriving it is expensive,
  non-deterministic or needs data unavailable at authoring, provided you record the CONSTRAINT that
  generates it, and this dimension does NOT reopen resolved-once capability records, which the
  ECOSYSTEM ADAPTER already discharges. OPERAND — cross-check any set reached through a PROXY
  against a direct enumeration of the underlying thing; a selection property must describe the
  item's INTRINSIC shape, never tooling or process residue, or it correlates inversely with need.**
- **SESSION-CLOSE VALIDATION's scope is now quantified, not enumerated:** it named "any living-plan
  doc", so it never reached other authoritative surfaces a plan's dispositions are actually read
  from. **Upgraders: widen the trigger to any authoritative artifact a plan's dispositions or
  standing rules are read from — a large accreting working index and the machine state included —
  and run the internal-consistency arm ACROSS SECTIONS of each artifact, not only per item, since a
  disposition table and a completion register inside one artifact can each be well-formed while
  contradicting each other. RIPPLE THE WIDENED TRIGGER TO WHEREVER YOUR CLOSE RITUAL RESTATES IT: a
  gate whose definition widened while its invocation still names the narrow scope is a gate that
  reads "skip" and "validate" for the same session. Both arms of the gate hang off that single
  widened antecedent, so the DRY-SYNC arm's own text is unchanged but it now fires in the wider
  case too.**

## Integration posture + selection-not-breakage + a register checkpoint

Migration entries folded in the pass that bumped the master to `v12-cinnabar-drumlin-hornbeam`. This
section's anchor is **derived from history** (the commit that assigned that version), not embedded
here. All are behavior-changing master or shared-harness edits. Behavior-neutral repairs landed in
the same commit are git-history-only and add no entry here.

### Master protocol (`living-plan-bootstrap.md`)

- **INTEGRATION POSTURE — a THIRD per-repo property resolved at cold start:** `commit_ownership`
  answers WHO commits and the co-occupancy condition answers whether the tree is exclusively yours;
  neither answered what the host's standing ROUTE from a local change to a landed one is, so that
  route was re-derived every session and guessed differently each time. **Upgraders: resolve an
  integration posture at cold start from HOST PROPERTIES — branching on the property, never on a
  host name — and record it in the new `ecosystem.integration_posture` slot described under the
  shared harness below, one field per output. It fixes four things. (1) THE DEFAULT VEHICLE:
  where the host protects its trunk and lands every change through a reviewed unit, make the
  isolation-plus-integration vehicle the STANDING DEFAULT rather than a response to DETECTED
  co-occupancy — detection is unreliable and the failure is asymmetric. Co-occupancy still FORCES
  isolation where a posture would permit a direct commit, never the reverse, and the vehicle's
  location property binds in both cases. (2) THE PUSH POINT: pushing is warranted by DURABILITY and
  cross-session VISIBILITY, NOT by concurrency, so where your posture pushes at all, push at the
  FIRST commit and keep pushing — if you derived your push point from the concurrency condition, you
  derived it from the narrow case. (3) THE DRAFT-VERSUS-READY GATE: resolve whether your host's
  draft state SUPPRESSES automated review, because where it does, dev-complete work handed over as a
  draft starts no review at all; then split by INTENT — a progress surface for in-flight work stays
  draft, work handed over for review is opened READY. (4) HOW PHASE, BRANCH AND REVIEW BIND: this is
  now a posture OUTPUT rather than the constant `phase = branch = review sitting`, so record the
  resolved binding instead of re-deriving it against a steer each time. A posture never overrides
  `commit_ownership` and never promises isolation the substrate does not deliver.**
- **Source-masking now fires on SELECTION, not only on breakage:** the rule was written for
  "something generated is BROKEN, fix the source", so it slipped past the two moments that most need
  it, neither of which presents as brokenness. **Upgraders: treat the rule as firing whenever a value
  determined by its inputs is about to be SELECTED by a cheap structural shortcut rather than
  RE-DERIVED from those inputs, broken or not. Two concrete consequences. A generated artifact in a
  merge conflict has NO correct side — both parents can be stale relative to the merged inputs — and
  the ours/theirs labels INVERT with merge direction, so side-selection is both semantically wrong
  and easy to apply backwards; regenerate from the merged source instead. A remediation pin-back has
  a FLOOR as well as a ceiling: every input your CURRENT configuration already consumes bounds the
  hold from below, so a revision chosen against the breakage alone fails for the opposite reason —
  prefer a revision a sibling consumer has already PROVEN over one read off topology. And after ANY
  such resolution, re-verify the PARTICULAR derived values that carry current intent against what the
  durable record says they should be; the shortcut's product is internally valid and passes every
  gate, so a green whole is not evidence.**
- **STANCE gains a structural pre-send CHECK for the chat register:** the two-register rule was sound
  and kept failing, because generation adopts the register of whatever was most recently read or
  written and register — unlike content — has no checkpoint, so drift is never caught while it
  happens. **Upgraders: before sending a chat reply, run a decidable test over its SURFACE rather
  than its meaning — does it carry section headers, tables, nested label-lists, or a bare internal
  label as the sole handle? Any hit means the wrong register; rewrite before sending. Scope the test
  to the reply's PROSE — a fenced handoff or kickoff block, and a register/agenda snapshot the
  protocol mandates, are dense BY INSTRUCTION and are exempt, or the check would fire on the
  presentations the close ritual requires. It binds hardest immediately after emitting a dense
  artifact, which is where the drift concentrates. This replaces exhortation with a checkpoint; the
  register rule itself is unchanged.**
- **The close PRECONDITION's never-armed exit now excludes a suppressor you can lift yourself:**
  adjudicating a reviewer's silence on observable side effects cannot distinguish "never armed for
  this unit class" from "armed but SUPPRESSED", and the commonest suppressor is a session's own
  integration request left in a draft state on a host where draft gates the reviewer. **Upgraders:
  before taking the never-armed exit at close, rule out a suppressor the session can itself lift —
  chiefly your own draft state; a liftable suppressor is un-gated work remaining, not an exit.
  Otherwise the exit discharges the precondition by forfeiting exactly the review it exists to
  secure.**

### Shared harness (`state.schema.json`)

- **New additive `ecosystem.integration_posture` object:** the posture is a per-repo PROPERTY that
  downstream rules dereference, so it needed an address and a shape rather than the freeform
  capabilities map that holds capability BINDINGS. **Upgraders: nothing breaks — every field is
  optional and additive, so a plan authored before this stays schema-valid. When you re-pin, resolve
  the posture at your next cold start and record it with one field per output:
  `default_vehicle`, `push_point`, `draft_policy`, `phase_branch_review_binding`. Record it even
  where the answer is the old default (direct commits on a branch, phase = branch = review sitting),
  because the rules that read it cannot tell an unresolved posture from a resolved permissive one.**

## Address discipline + a freshness arm, a reader-side raiser, split verdicts, a standing grant

Migration entries folded in the pass that bumped the master to `v13-orpiment-esker-blackthorn`. This
section's anchor is **derived from history** (the commit that assigned that version), not embedded
here. All are behavior-changing master or shared-harness edits. Behavior-neutral repairs landed in
the same commit are git-history-only and add no entry here.

### Master protocol (`living-plan-bootstrap.md`)

- **A TRACKED PATH IS AN UNDER-SPECIFIED ADDRESS — the write-side gitignored-but-tracked gotcha
  generalizes into one address-discipline clause with four instances:** the old clause covered
  writing only, and named committable status as the sole predicate a successful write fails to imply.
  The property is wider — a path fixes a NAME, never WHICH CONTENT that name holds, and every path
  resolves at once against a working copy, a staged copy, committed history and, under multiple
  working trees, a TREE. Which one a tool reads is a property OF THE TOOL, chosen silently, so a
  result drawn from the wrong store is well-formed and plausible: never empty, never an error,
  nothing the emptiness and fidelity rules would catch. **Upgraders: before treating any write,
  proof, search, read or commit as fact, establish WHICH store and WHICH tree it reached. Four
  instances carry their own remedies and they resist collapsing because they push OPPOSITE ways on
  the same object — one instance's remedy manufactures the next one's hazard — which is why they
  stay concrete. (1) The write-side clause keeps its remedy and gains the two ways it fails,
  which turn on the PATHSPEC'S BREADTH: reached by a BROAD pathspec an ignored path is skipped
  silently at a ZERO exit, while named EXPLICITLY the add exits non-zero and reports the IGNORE
  RULE'S MATCH — often the ignored DIRECTORY, which may be the parent of a path that staged fine —
  and never the members that succeeded, which stage anyway. An add of an already-tracked path
  under such a subtree exits non-zero even when it fully succeeds. So the exit status is not a
  refusal signal there and the named path is not the failure: RE-READ THE INDEX to learn what
  landed. (2) A tool resolving its INPUTS from version control cannot see an unstaged new file
  and reports a MISSING path that reads as real breakage, while every filesystem-level proof
  passes over that same file — stage before invoking; staging suffices, no commit needed. (3)
  Staging SNAPSHOTS bytes, so anything staged before its last edit ships a revision no proof
  reached, and a pathspec-less commit ships the whole staged set rather than the unit — so commit
  by explicit pathspec, and prove the copy that commit form ACTUALLY reads: a pathspec-LESS commit
  ships the index, while a pathspec-BEARING one ships the working tree for the named paths and
  disregards what CONTENT was staged for them (a path git does not already know cannot be named at
  all, so a brand-new file must still be staged once). Pick the form first, prove that store last,
  and let nothing
  — a formatting hook above all — write in between, or the one-unit-one-commit binding silently
  stops holding. There is no ambient tell for either. (4) A repo-relative path, or a
  host-advertised workspace root, resolves against the HOST's tree and not necessarily the one you
  are changing — bind the tree at the POINT OF USE by addressing the active tree's absolute root.
  Do NOT bank that as a resolved-once environmental property: the answer inverts the moment an
  isolation vehicle is materialized. And do not derive it from the COMMON git directory, which
  reaches the MAIN checkout by construction — that derivation is sanctioned as a namespace key and
  as a vehicle location, and is now explicitly barred as a read or search root. Under
  resident-commits the same discipline applies to the handover: derive the "please commit these
  paths" note from THE PATHS YOUR SESSION ITSELF WROTE — every one of them, since that mode
  commits nothing during the sitting — rather than from tree state, which may hold another
  writer's work.**
- **The no-ignore rule reaches any PROBE, not searches alone:** the ignore-honoring default was
  stated for search, so the neighbouring diagnostic failed unremarked — an ignore-STATUS query that
  consults the index answers EMPTY for an already-tracked path and reads as "not ignored" exactly
  where the tracked-under-ignore case applies. **Upgraders: use the no-ignore form of any probe of
  such a subtree, and treat an empty ignore-status answer on a tracked path as uninformative rather
  than as a negative.**
- **A LIVE CONSUMER OF THE TARGET now raises the isolation vehicle, as a third raiser:** the vehicle
  was raised only by the posture or by a co-occupied tree, and both ask about a second WRITER. Every
  condition resolved at cold start is a property of the ENVIRONMENT or of the plan; none is a
  property of the ARTIFACT BEING MODIFIED. **Upgraders: before an edit lands on an artifact anything
  outside the session can load, answer whether something is executing it right now. A consumer that
  loads its artifact incrementally, or re-reads it as it runs, executes a half-applied or
  version-split copy; the damage lands inside that consumer and is invisible to you, so this is
  SILENT, not self-announcing. Where the consumer reads a path the vehicle relocates, in-use raises
  the vehicle exactly as co-occupancy does. Where it does not — a consumer reading INSIDE the
  vehicle, or a copy no vehicle covers, your out-of-repo working state and any installed or
  activated copy among them — isolation is NOT the remedy and the edit WAITS. A validated atomic
  replace removes only the TORN read, never the SPLIT one, so it is a floor rather than a substitute
  for waiting. Do NOT record this in your resolved-property record: it is not standing truth (a
  consumer may begin using the target after cold start) and it is answered at edit time. Where you
  cannot observe the answer, ASK — an unverifiable property is worse than a question. Three sites
  that enumerated the two old raisers now name the raiser SET instead; if you copied any of them,
  re-point rather than extend.**
- **A SPLIT VERDICT IS ADJUDICATED, NOT TALLIED, and the verifier brief now fixes each claim's
  SCOPE:** delegated verification fixed what ARRIVES — claims under test, per-claim verdicts, no
  rollup — and said nothing about what to do when two verdicts on ONE claim disagree, which is the
  expected consequence of fanning review out by LENS rather than by finding. **Upgraders: stop
  letting an aggregation step resolve a split. Filtering to survivors drops the claim because one
  verifier refuted it; keeping anything confirmed keeps it because one did not; both are silent and
  defensible, so which runs is an accident of how the aggregation was written. Decide the claim on
  the evidence each verdict carries. Counting is the wrong instrument: independent skeptics are
  countable only against ONE FIXED PROPOSITION, and split verdicts may have scoped the claim
  differently — so establish first that they answered the same question, and where they did not,
  split the claim into the parts each addressed. Treat a split as EVIDENCE: a claim competent
  readers divide on is likelier substantive than one they agree on, so an unresolved split leaves
  the claim OPEN rather than resolved by default. Add scope-fixing to every verifier brief; it is
  the precondition that makes a genuine disagreement distinguishable from two answers to two
  questions.**
- **AN ESCALATION IS A DISPOSITION AND GOES STALE — the decision-scope filter gains a freshness
  arm:** the filter ran when a call AROSE and nothing re-ran it over a call already recorded as
  human-owned, so a held set was carried and re-presented indefinitely on dispositions nothing
  re-tested. Neither existing arm reaches it: the forward arm fires before an item is BUILT and an
  escalation is never built, and the backward arm turns on contact with the real system that a
  question waiting in a register never makes. **Upgraders: re-run the filter over every unresolved
  item held for the human, wherever recorded, at the moment it would be put in front of them again,
  however carried — and assemble any opening agenda from those re-derived dispositions rather than
  reading them off the register. An item the recorded decisions now answer, or that an authoritative
  source the escalation never consulted has since settled, is no longer an unknown and is resolved
  non-interactively before the gate opens; what is artifact-internal is agent-owned and is decided,
  applied and logged. Re-derivation runs BOTH directions and never silently retires a question: a
  disposition that moves is marked changed where it sits, and one that survives is asked with its
  reason intact. This is a checkpoint, not a re-decision — the structural reason each disposition
  already carries is what the re-run tests against current facts.**
- **A STANDING OPERATOR AUTONOMY GRANT IS PLAN STATE, not kickoff prose:** whether a boundary WAIT
  is what this operator wants is a durable property of the PLAN, but it rode in the kickoff, which
  is convenience and explicitly non-authoritative — so a session starting from state alone could not
  see it, defaulted back to WAIT, and contradicted the standing intent. **Upgraders: record such a
  grant in the new `operator_autonomy` slot described under the shared harness below, with the
  operator's authorization as provenance exactly as a sanctioned override carries its own. It FAILS
  SAFE BY ABSENCE — no recorded grant means WAIT, and a grant is never inferred from a session's
  tone, from work proceeding smoothly, or from a prior session having proceeded. It NARROWS rather
  than lifts: it changes what a phase_boundary does and nothing else, so a hitl_opening still waits,
  every human-gated item still gates, and the register presentation the opener already owes is still
  made. Replace it IN PLACE when the standing intent changes; a withdrawn grant appended to rather
  than replaced leaves a superseded clause still reading as live.**
- **The durable-record rule is scoped by RECORD-PRESENCE, not by machinery tier:** it sat under the
  full-tier additions, which tell a LITE plan to skip the section, while the rule binds every tier.
  **Upgraders on LITE: you are in scope. Your session and decisions logs are the durable record, so
  answer authorship, presence and ABSENCE claims about your own work from them and never from
  recollection, and assert at close both that the record carries an entry from this session and that
  the position marker was re-derived rather than inherited. Only the write side's diagnosis — the
  per-unit WAL trigger — is full-specific; its remedy is not.**

### Shared harness (`state.schema.json`)

- **New additive `operator_autonomy` object:** a standing grant that changes what a position class
  DOES is a durable property of the plan that a rule dereferences, so it needed an address rather
  than a re-conveyed prose token. **Upgraders: nothing breaks — the object and every field are
  optional and additive, so a plan authored before this stays schema-valid, and absence means the
  position class behaves exactly as written. Record `proceed_past_phase_boundaries` only on an
  explicit operator grant, with `provenance` naming the authorization it rests on and `conditions`
  carrying what the grant obliges in exchange (canonically, that every decision taken past the
  boundary is documented). An unrecorded go-ahead is a defect: a grant with no provenance cannot be
  told from one a session invented for itself, and the harness now ENFORCES that rather than only
  asking for it — setting `proceed_past_phase_boundaries` to true without `provenance` and
  `conditions` is schema-invalid. Validation is lenient about ABSENCE and strict about ASSERTION, so
  the conditional cannot invalidate a plan authored before the field: such a plan asserts nothing.**

## Graded bounds + a round over the fix text

Migration entries folded in the pass that bumped the master to `v14-realgar-moraine-rowan`. This
section's anchor is **derived from history** (the commit that assigned that version), not embedded
here. Both are behavior-changing master edits, and each adds an arm to a rule family that was
already sound — the first to the dispatch-bounds dropped-item clause, the second to the review
family. Behavior-neutral repairs landed in the same commit are git-history-only and add no entry
here.

### Master protocol (`living-plan-bootstrap.md`)

- **A bound over a GRADED work-list consults the grade, and the stage reports coverage by
  grade:** the dropped-item clause under dispatch bounds fixes WHETHER an omission is visible and
  settles nothing about WHICH items may be omitted, so a bound blind to the grade strands the
  highest-graded items exactly as readily as the lowest, and the duty to log the overflow is
  discharged without anyone learning what the overflow contained. **Upgraders: where a stage bounds
  work over a set whose items carry their own severity or priority, order the drop from the
  LOW-GRADE end first, and report that stage's coverage BY grade rather than as one total. A stage
  reporting zero survivors over a set it never reached the top of has exactly the shape of a clean
  pass — the qualifier lives in a count and a log line the headline does not carry, so the more the
  stage produced the more confident and the more wrong its reader becomes. Treat an item of the
  BLOCKING class that went untested as not disposed of at all: CONVERGENCE turns on no blocking
  finding REMAINING, and one never tested has not been shown not to, so it holds convergence open
  exactly as a surviving one does. Nothing here loosens the existing duty to surface every dropped
  item; it says what to do when what was dropped is the part that mattered most.**
- **The text written to fix a review round is itself reviewed, in a round scoped to it:** the
  review family had no account of its own last step. A round finds defects, the author fixes them,
  and those fixes are new text no round has read — written last, under the most fatigue, and
  covered by none of the confidence the completed rounds earned. **Upgraders: before handing a
  change over, run ONE further round scoped to the fix text and its neighbours, rather than a
  further FULL round. No round eliminates the hazard — its own fixes inherit it — so the asymmetry
  is not termination but corpus: the scoped round reads only what the fixes touch, while a full
  round re-reads the whole change again. Log an explicit acceptance of the residual the scoped
  round leaves rather than assuming it away. Treat it as required rather than as polish. And when a
  fix resolves a CONTRADICTION by editing one side of a coupled pair, re-check the edited statement
  against its immediate NEIGHBOURS and not only against the statement it was reconciled with: the
  pair contradicted only because it described one thing from two angles or at two levels, so the
  edited side commonly now disagrees with a THIRD statement the original wording satisfied, and
  that third statement is usually the nearest one.**
