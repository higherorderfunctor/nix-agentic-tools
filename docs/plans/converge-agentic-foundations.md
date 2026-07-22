# Converge agentic foundations — living plan

Unifies three paused workstreams — (a) materialization (symlink vs real file),
(b) typed hook surface, (c) agent-primitive labs — into one worktree- and
subagent-driven plan. End state: repo mechanics (materialization class) fixed,
hooks working end-to-end, labs/fixtures operational — so harness-engineer test
prototyping can begin on top of them.

**Protocol:** this is a LIVING PLAN under
`.claude/skills/dev-living-workflow/references/living-plan-bootstrap.md`
(master, `v8-onyx-moor-rowan`) + `state.schema.json` beside it (referenced,
never re-embedded). Machine state (authoritative):
`${XDG_STATE_HOME:-~/.local/state}/living-workflows/nix-agentic-tools/converge-agentic-foundations/`
(`state.json` + `journal.ndjson`). This doc is the durable/human snapshot;
state.json wins on disagreement. Tier: FULL. Mode: cli (confirmed by operator's
convergence directive — worktree + subagent driven, this machine).

## CURRENT POSITION

Mirrors `state.json.current_position` — read that first. At plan creation:
`P1 / hitl_opening` — batched P1 agenda awaiting operator; intake + verification
complete.

## Session bootstrap (every session)

1. Read `state.json` + tail of `journal.ndjson` at the state root above.
2. Follow the master protocol's EMBEDDED SESSION BOOTSTRAP (warm start: earliest
   not-done unit; act by position class; commit gates per ecosystem block).
3. Load only the working set: this doc's phase section for the open phase, plus
   the source docs it names. Do not re-read all source docs every session.

## Source docs (committed, read-first per phase)

- `docs/plans/session-state/materialization.md` — session (a) state, 10-section
- `docs/plans/session-state/labs-fixtures.md` — session (c) state
- `docs/plans/build-typed-hook-surface.md` — session (b) plan snapshot
- `docs/plans/factory-steering-materialization-decision.md` — decision +
  tradeoffs + 6 incidental defects
- `docs/plans/agent-primitive-labs-design.md` + `agent-primitive-labs-impl-plan.md`
  — labs spec/plan (impl plan's Parked items P1–P14 drained into this register;
  section to be deleted per its own exit gate)
- `docs/plans/steering-symlink-probe/run-probe.sh` — self-tested reproducer (P14)

## Verified base state (intake 2026-07-21 — corrections to the handoffs)

Facts below were adversarially verified against git/code; where a handoff claim
was stale, THIS section wins. Do not re-inherit handoff claims without checking
here first.

- **Base divergence RESOLVED.** Local `refactor/ai-factory-architecture` ==
  `origin/...` at `b3906bd9` (0/0). Session #2's "9 PRs behind + 5 unpushed"
  gating item is satisfied; PR #433 squash `af53cf63` IS an ancestor of HEAD.
- **REFUTED: "HM Kiro hooks emitter never converted."** Current tree delivers
  general `ai.kiro.hooks` via `home.activation` real files
  (`packages/kiro-cli/lib/mkKiro.nix:631-643`). Session (a)'s §9 claim predates
  #433. No work item.
- **CONFIRMED: repo-wide `entryAfter ["writeBoundary"]` defect** (should be
  `["linkGeneration"]`; siblings, toposort order config-dependent). Sites:
  `mkKimchi.nix:255,266`; `mkKiro.nix:637,649,744`; `mkCopilot.nix:323`;
  `mkClaude.nix:508`; plus mcp-servers. Zero uses of `linkGeneration`.
  module-eval's dag stub discards `after`/`before` — cannot catch this.
- **CONFIRMED: mkClaude devenv `ai.mcpServers` broken** — raw typed schema
  passed at `mkClaude.nix:657-660`; HM branch renders via `lib.ai.renderServer`
  at `:492-494`. Masked in-repo by `devenv.nix:186` setting upstream directly.
- **CONFIRMED: the only real-file-vs-symlink gate never runs in CI** —
  `devenv.nix:315-346` enterTest; no workflow invokes it.
- **Location correction:** the wrong-product Kiro IDE citation (#2921/#8121)
  is at `mkKiro.nix:863-865` (handoff said :794). Correct citation:
  `kirodotdev/Kiro#9787` (kiro-cli, v3, OPEN, maintainer-acked). Comment must
  name the ENGINE (v2 follows leaf symlinks; v3 drops them).
- **CONFIRMED: stale hashes** in `build-typed-hook-surface.md:46,75`
  (`3050f894`/`bd67936f`/`cf71e9cd` resolve but are NOT ancestors of HEAD;
  on-branch equivalents `f12aa5f1`/`a7b3e29d`/`88f1fc8b`).
- **Cherry-pick of `0222a0eb` (u1) onto HEAD is CLEAN** (parent-base
  merge-tree). Known follow-up: its module-eval golden asserts pre-#433
  `home.file` delivery and must re-point at `home.activation`;
  `kiro-auto-memory.md` fragment needs reconciling with #433's version.
- **Labs branch:** `refactor/agent-primitive-labs` clean at `a4560b77`,
  6 commits, fork point `010dbe15` = 19 commits behind HEAD. Zero deletions.
- **Worktrees:** `agent-primitive-labs`, `kiro-hook-colocation` (both live
  work); `typed-hooks-kiro` (454b091c), `typed-hooks-phase1a` (d964ae1c)
  presumed superseded — cleanup gated HITL.
- **Three failure axes stand** (labs §6.2 as corrected by (a)): _scope_ (Kiro
  v3 reads NO global hooks — real-file-proven, pre-#433, must re-run), _delivery_
  (factory steering/skills/agents emitters still ship store symlinks to every
  consumer; only repo-local files + HM hooks are fixed), _wiring_ (typed surface
  landed). Fixing one axis never fixes another.

## Hard constraints (binding; from the decision doc + sessions)

1. Never `force = true` on a steering `home.file` (HM silently deletes the
   target; `contextFilename` defaults to `AGENTS.md`).
2. Never fold emitter branches with `//` — collisions must BECOME hard
   eval errors. (The original "must stay errors" premise was false:
   today's `home.file` text merge silently CONCATENATES colliding
   definitions — only the module-eval stub errored. The materializer's
   `nullOr str` upgrade on `steeringFiles.<n>.text` makes the error
   real; `//` would instead be silent last-wins.)
3. Never blind-prune `~/.kiro/steering/` (user-owned) — manifest-prune only.
4. A user edit to a managed file must never be silently clobbered.
5. HM copy-activation ordering: `entryAfter ["linkGeneration"]`, never
   `["writeBoundary"]`.
6. Materialization = `strategy = "copy"|"symlink"` data on a declarative
   attrset consumed by ONE shared materializer (`lib/ai/materialize.nix`);
   module-eval asserts on the attrset; git-tracked outputs are just
   `strategy = "copy"`.
7. Copy-mode implementations heredoc-embed content (HM #433 precedent), never
   interpolate store paths (devenv 38b7088f lost content assertions).
8. Claude surfaces stay symlinks (verified working). Kiro skills/agents:
   probe-first with WORKING controls, never convert on speculation.
9. `sync_file` needs a `[ -L "$2" ]` force-write guard before any port (its
   `cmp` follows symlinks — identical-content destination symlink survives).
10. Kiro v3 probes need a pty (`script -qec "kiro-cli chat --tui --v3 …"`) +
    hard-assert `[KiroAgent]`; A/B probes must swap names. `--no-interactive`
    without a pty silently runs v2.
11. Labs isolation: never set `XDG_DATA_HOME`/`HOME` (kills Kiro auth DB);
    `CLAUDE_CONFIG_DIR` + empty `CLAUDE_SECURESTORAGE_CONFIG_DIR` + `KIRO_HOME`;
    labs live outside `$HOME` (CLAUDE.md ancestor-walks to /home); `cp -rL` +
    `chmod -R u+w`, never `--no-preserve=mode`.
12. Execution: single-job builds only (`nix build --max-jobs 1 --no-link
.#checks.<sys>.<name>`); no parallel eval fan-out; subagents ≤10 bounded
    queue; commit/push only on operator ask; nixos-config + live HM switches
    HITL.

## Phases

Greedy-scheduled: P1 is cheap and unblocks everything; P2 carries the highest
revision-cost decision (materializer design) and so lands before any emitter
work; P3 hooks/probes partly parallel to P2 (independent surfaces, own
worktrees); P4 labs payload consumes P1's rebase; P5 is the goal state.

### P1 — Base normalization + intake close (this session; ~1 session)

Everything rebases onto one tip; kills all cross-session staleness. Units:

- u1-labs-rebase: rebase `refactor/agent-primitive-labs` onto `b3906bd9` in its
  worktree. Hand-resolve `flake.nix` only; regenerate `devenv.yaml`
  (`nix eval --raw --impure --expr 'import ./config/generate-devenv-yaml.nix {}'
  > devenv.yaml`), `flake.lock`/`devenv.lock`; union
`config/cspell/project-terms.txt`. Then targeted single-job check builds.
- u2-land-u1: in `kiro-hook-colocation` worktree, rebase `0222a0eb` onto tip;
  re-point golden `module-kiro-hooks-typed-colocation` at #433
  `home.activation` delivery; reconcile `kiro-auto-memory.md` fragment;
  `nix build --max-jobs 1 .#checks.<sys>.module-kiro-*`; squash-PR
  (github-mcp; `gh pr create` is hook-blocked) — PR gated on operator OK.
- u3-doc-hygiene: fix stale hashes (`build-typed-hook-surface.md:46,75`);
  annotate labs §6.2 correction pointer; drain P1–P14 from the impl plan's
  Parked items into this register + delete that section (its own exit gate).
- u4-inline-fixes (labs-dispositioned FIX INLINE 2026-07-21): devenvModules
  naming (README.md:87, dev/generate.nix:511, etc.); phantom
  `generate:devenv-yaml` task (add the task — matches sibling generators);
  `flake.nix:219` false comment; dead `checks/devshell-eval.nix`.
- u5-fold-typed-state: mark `typed-hook-surface/state.json` folded →
  points here (its `next_action` already declares the park-for-unify).
- u6-worktree-cleanup [HITL]: verify `typed-hooks-kiro` / `typed-hooks-phase1a`
  fully merged, then tear down.

### P2 — Materializer design synthesis → decision → build (~2 sessions)

Highest fan-out. Synthesize ONE design honoring constraints 1–9 from the three
fatally-flawed candidates (author's sketch: keep the four mkMerge branches, add
a derived attrset for assertions, put `strategy` on it) + adversarial coherence
review (DESIGN-PHASE COHERENCE REVIEW per master) → **HITL design decision** →
implement: shared materializer; convert Kiro steering (verified: 4 HM + 4
devenv emitter sites);
repo-wide `writeBoundary`→`linkGeneration`; `sync_file` guard; re-correct
`mkKiro.nix:863-865` + engine qualifiers (same commit); fix
`instruction-file-single-mechanism.md:169-171`; wire enterTest gate into CI;
regen instruction files (oi-regen-instructions). devenv whole-dir-symlink
shortcut for project scope: evaluate as part of the design, not a bolt-on.

### P3 — Hooks convergence + probe settlement (~2 sessions, partly ∥ P2)

Scope questions decide what delivery is worth building. Re-run global-hooks
probe post-#433 (rig `/var/tmp/nat-kiro-probe/`); P13 workspace-symlink control
[HITL]; skills probe with working control (2.12.3-fixed hypothesis); agents
probe; global steering under v3; investigate autoMemory-dead-under-v3
hypothesis (NOT established). Then typed-surface completion: telemetry
hook-fire JSONL test-wrapper (OFF by default, test-only); migrate autoMemory
onto file-grouped typed records; retire hooksJson (nixos-config repin HITL).
Ownership boundary (settled): labs owns testing; consumes the typed surface
as-shipped.

### P4 — Labs payload (~1-2 sessions)

Skill-trigger lab (Task 5 — the first real experiment, unblocked after
u1-labs-rebase); port steering-symlink probes as permanent lab fixtures (P14);
nmt adoption prep (P11: real-module eval + byte-level assertions; retire
~3,723 stub lines in `checks/module-eval.nix`; upstream ships 60 claude-code
test files as drift oracle) → adoption decision at phase close.

### P5 — Harness prototyping enablement (goal; open-ended)

First harness-engineer test fixtures composed from working hooks + working
materialization + labs. Entry criterion: P2 emitters converted, P3 hook scope
settled, P4 payload lab runs. Backlog items below feed this phase's design.

## Open-items register

Dispositions per master schema; every entry carries its structural reason in
state.json. High-level (grouped by phase; ★ = HITL):

**P1:** labs-rebase · land-u1+golden-repoint+fragment-reconcile ·
★u1-PR-creation · stale-hash fixes · staging-section drain ·
inline-fixes batch · fold-typed-state · ★worktree-cleanup
**P2:** ★materializer-design-decision · emitter-conversion ·
writeBoundary-fix · sync_file-guard · citation-recorrect ·
instruction-doc-fix · enterTest-CI-wiring · enterShell-cwd-anchoring
(mkKiro.nix:812-819, diagnose then fix) · ★mcpServers-devenv-fix
(severe; render via lib.ai.renderServer — behavioral, needs approval) ·
env-vars-devenv (needs diagnosis) · regen-instructions
**P3:** ★global-hooks-probe-rerun · ★P13-workspace-symlink-control ·
skills-probe · agents-probe · global-steering-probe ·
autoMemory-v3-regression-check · telemetry-test-wrapper ·
autoMemory-typed-migration · ★hooksJson-retirement (nixos-config repin)
**P4:** skill-trigger-lab · probe-fixtures (P14) · ★nmt-adoption ·
labs-x86-only [DEFAULT: x86_64-linux-only, revisable]
**P5:** harness-prototype-fixtures
**Backlog (parked):** loop-engineering-style module-unit architecture
(cobusgreyling/loop-engineering as reference — clean module units; nix fanout
for cross-CLI harness support; hooks for workflow optimization/control flow) ·
knowledge-base fold (hold impl against the researched KB — bridge-or-not
evaluation; feeds telemetry/fixtures/memory-systems work) ·
copilot-projectDir-hardcode (mkCopilot.nix:450,461) ·
★promote-refactor-to-main (post-plan; interacts with re-chunk-for-main) ·
worktree-output-relocation (research banked) ·
namespace-unify-later [NEEDS-EVIDENCE, pinned, carried from typed plan] ·
full-hookset [DEFAULT, carried] · devenv-dir-symlink-shortcut (project scope)

## Standing rules

Master's STANDING RULES apply verbatim (field-report laundering, completionist
mode, mechanism creep, provenance laundering, convergence declarations,
degradation-by-shrug, source-masking, prove-against-reality). Plus, from the
sessions: treat unverified command syntax in inherited docs as suspect (four
defects came from asserted-but-unrun commands); Nix 2.34.4 error phrasing is
"does not provide attribute" (never broaden); devenv tasks have no positional
args (`--input k=v` only); the devenv-scoped `kiro` wrapper rejects
`--tui`/`--v3` (use `kiro-cli`).

## Cold-start seed

Derivable from the sections above: phases P1–P5 (P1 open, rest pending), units
u1–u6 under P1, the register as listed, budget unit=units soft_close 75%.
state.json at the state root is authoritative thereafter.
