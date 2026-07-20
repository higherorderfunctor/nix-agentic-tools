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
