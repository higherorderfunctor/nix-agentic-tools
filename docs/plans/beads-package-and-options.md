# Beads: overlay package and `ai.*` option surface

> **Status: DESIGN** — phase 1 of 3 (this document set). Created 2026-08-14.
> Companion references, synthesized from prior research sessions and re-verified
> where marked: `docs/beads/bd-reference.md` (the tool),
> `docs/beads/dolt-git-remotes.md` (sync/remote mechanics),
> `docs/beads/ecosystem.md` (integrations and prior art). Facts in this plan
> that duplicate a companion are deliberate summaries — the companion is
> authoritative; update both in the same commit.

## Goal

Adopt beads (`bd`, the Dolt-backed graph issue tracker for coding agents) as a
first-class citizen of this repo:

1. **Overlay package** — `pkgs.ai.devTools.beads` on the standard update
   pipeline (phase 2, unblocked).
2. **Option surface** — HM + devenv modules with config parity, wiring bd's
   integration surfaces through the `ai.*` factory to the supported runtimes
   with opinionated defaults (phase 3, gated).
3. **Git-ref-backed sync** — support a Dolt remote riding an ordinary git remote
   (`refs/dolt/data`) with an explicit checkpoint/push workflow, usable from a
   home-manager-only machine (phase 3, partially gated).

**Out of scope here:** the protocol design of any specific consumer (for
example, using bd as the task store behind a particular planning workflow —
nothing in this plan depends on such a consumer), and the semantic
dedup/indexing layer (recorded in `docs/beads/ecosystem.md`; its decisions are
deferred below).

## The consumption discipline: pure data engine

Beads self-wires aggressively — `bd init` writes AGENTS.md, installs git hooks,
and runs git-ops in the repo; `bd setup` installs per-runtime integrations;
there is a first-party Claude plugin. **All of that is disabled here.** A tool
self-configuring the environment is the anti-pattern this repo exists to
eliminate: beads is consumed as a pure data engine, and every integration
surface it would self-install (binary, MCP server, context snippet, skill,
session-start hooks, env, permissions) is declared through the `ai.*` HM/devenv
factory instead. Concretely:

- Init only ever as `bd init --quiet --skip-agents --skip-hooks` (or
  `--stealth`), with `no-git-ops: true` — and the `no-git-ops` config is
  **load-bearing, not belt-and-suspenders**: `BEADS_DIR` bypasses git-repo
  discovery only when the env var is present in an invocation, and `bd` runs
  with cwd = repo root, so the config must live where `bd` reads it _without_
  the env var (project-local `.beads/config.yaml` or the user-global config).
  Details in `docs/beads/bd-reference.md`.
- Telemetry off is a hard requirement (`BD_DISABLE_METRICS=1`,
  `BD_DISABLE_EVENT_FLUSH=1`).
- Hooks and wrappers that cannot resolve their workspace must **emit a signal**,
  never silently no-op — an env-delivery failure must not present as "beads just
  never primes."

## Phases and gating

| Phase | Deliverable                                        | Gated by                                          |
| ----- | -------------------------------------------------- | ------------------------------------------------- |
| 1     | This document set                                  | —                                                 |
| 2     | `overlays/dev-tools/beads.nix` + registrations     | OD-P1/OD-P2 veto window (defaults proposed below) |
| 2b    | `overlays/mcp-servers/beads-mcp.nix`               | OD-P3 (timing); technically unblocked             |
| 3     | `packages/beads/` HM + devenv + lib option surface | rework PR 7b (naming), OD-M1..M5, probes          |
| 3b    | Git-ref Dolt remote options + checkpoint workflow  | OD-M4; encrypted variants additionally OD-D1      |

Phase 3's namespace question is deliberately deferred: the in-flight `ai.*`
rework (`docs/plans/ai-normalized-interface-rework.md`, PR sequence signed off
2026-08-14) introduces `ai.programs.<pkg>` / `ai.<runtime>.programs.<pkg>` in PR
7b, and beads' options should land in that shape rather than invent a pre-rework
namespace that PR 8 would then have to migrate. Surfaces can be _designed_ now
(below); they get _named_ after 7b.

## Phase 2 — the overlay (unblocked)

Verified 2026-08-14: this repo's pinned nixpkgs already carries `beads` 1.0.3
(`pkgs/by-name/be/beads/package.nix` — buildGoModule, ICU, MIT,
`mainProgram = "bd"`, and a `postInstall` wrapping `dolt` onto PATH) and `dolt`
(2.1.4 at the pin, Apache-2.0). So the overlay is a **thin override of
`ourPkgs.beads`** in the `gh` shape (`overlays/dev-tools/gh.nix` is the template
— Go, sidecar, grouped subtree), not a fresh derivation:

- `overlays/dev-tools/beads.nix` — `{inputs, final, ...}`, `ourPkgs`
  instantiated from `inputs.nixpkgs` (cache-hit parity: all build inputs from
  `ourPkgs`, never `final`/`prev`), `vu = import ../lib.nix`. Two seams:
  `.override { buildGoModule = vu.mkGoBuilder …; }` for the Go toolchain floor
  (mandatory — beads becomes the eighth Go package), then `.overrideAttrs` for
  `version`/`src`/`vendorHash`, merging `passthru` (never replacing — Go
  builders hang `goModules`/`overrideModAttrs` there) and exposing
  `passthru.fixVendorHash`/`fixGoFloor` for sidecar self-healing.
- `overlays/dev-tools/beads-sources.json` — sidecar written by
  `vu.ghArchiveUpdateScript { repo = "gastownhall/beads"; sourcesFile = …; extraExtract = fixVendorHash + fixGoFloor; }`
  (hash fixer first). Release-tracking mode, which also solves the version-pick:
  the sweep follows **stable releases** (v1.1.2 at the verify date) and never
  the v1.2.x prereleases that `llm-agents.nix` currently pins.
- The dolt PATH wrap is **inherited from the nixpkgs recipe** — verify at the
  pinned rev during implementation and do not add a second `wrapProgram`
  (double-wrapping is the trap; check with
  `ls -a $(nix build .#beads --no-link --print-out-paths)/bin` for a single
  `.bd-wrapped`).
- Registrations, all alphabetically placed: `overlays/default.nix`
  (`devToolDrvs`), `config/update-targets.nix` (binary row,
  `--override-filename overlays/dev-tools/beads.nix`),
  `config/cache-hit-parity-targets.nix`
  (`consumerPath = ["ai" "devTools" "beads"]`), `overlays/README.md`
  (hand-maintained index), `dev/data.nix` (`devToolDescriptions` — root README
  is generated; regenerate via `devenv tasks run --mode before generate:all`).
- cgo note: upstream needs ICU (`go-icu-regex` ships no `#cgo pkg-config:`
  line); the nixpkgs recipe already handles this on Linux — Darwin behavior is a
  CI question, not a local claim.

**What phase 2 does _not_ need:** any operator ruling on compilation strategy. A
"WASM instead of a Rust-compiled parser" packaging concern is sometimes
attributed to beads; it belongs to **codegraph** (whose numtide build is
WASM-tree-sitter-only with the native kernel optional) — `bd` is plain Go with
no parser toolchain in any inspected derivation.

### Phase 2b — beads-mcp

The official MCP server is Python (fastmcp, PyPI `beads-mcp`, versioned in
lockstep with bd) and shells out to `bd`. Package under
`overlays/mcp-servers/beads-mcp.nix` on the existing Python template
(`sympy-mcp.nix`), baking `BEADS_PATH` to the overlay's `bd`. Version rule: pick
the beads-mcp release paired with the pinned stable bd line (1.1.x at the verify
date); if PyPI carries only prerelease-lockstep versions, accept the skew
consciously — beads-mcp shells out to whatever `bd` it is given, so bd's own
schema guard is the real boundary (PB12 verifies). Its env surface (`BEADS_DIR`
supported, `BEADS_DB` deprecated — note this _refutes_ older research; see
`docs/beads/bd-reference.md`) must be re-verified at the pinned version when the
module wires the env block (PB12).

## Phase 3 — the option surface (gated)

`packages/beads/` in the standard facet-barrel shape: `lib/` (manual wiring
functions), `modules/homeManager/`, `modules/devenv/` — the config-parity rule
applies (every surface expressible in all three methods or recorded as an
explicit exclusion). Surface bindings, verified against the current tree
2026-08-14 (line numbers will drift; re-verify at build time):

| beads surface        | factory mechanism today                                                                                                                                                                                                                                                                                                                 |
| -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `bd` on PATH         | raw `home.packages` / devenv `packages` — no `ai.*` option exists (known gap)                                                                                                                                                                                                                                                           |
| beads-mcp            | `ai.mcpServers.beads` (`lib/ai/sharedOptions.nix:65`) with the server's own `env` block (`lib/ai/mcpServer/commonSchema.nix:169`); fans out to all runtimes including Codex                                                                                                                                                             |
| session-start prime  | portable `ai.hooks` (`lib/ai/sharedOptions.nix:221`, Claude+Codex) or `ai.claude.hooks.SessionStart` (`packages/claude-code/lib/mkClaude.nix:577`); Kiro via `ai.kiro.hooks` **UserPromptSubmit** (`packages/kiro-cli/lib/mkKiro.nix:1457`) — Kiro SessionStart cannot inject context; Copilot has no hook surface (explicit exclusion) |
| timer-gate check     | same hook surfaces as prime (`bd gate check`)                                                                                                                                                                                                                                                                                           |
| onboard snippet      | `ai.rules` keyed entry (`lib/ai/sharedOptions.nix:92`) — prefer over `ai.instructions`, which the rework retires in its PR 5                                                                                                                                                                                                            |
| skill                | `ai.skills` (`lib/ai/sharedOptions.nix:328`) contributed via `lib/ai/mkSkillPackageModule.nix`                                                                                                                                                                                                                                          |
| env / telemetry-off  | `ai.environmentVariables` (`lib/ai/sharedOptions.nix:254` — Codex, Copilot, Kimchi, Kiro) **plus** `ai.claude.settings.env` (Claude is excluded from the shared pool)                                                                                                                                                                   |
| permissions          | `ai.claude.settings.permissions.allow = ["Bash(bd:*)"]` (freeform) + `ai.kiro.permissions` (typed, `packages/kiro-cli/lib/mkKiro.nix:1355`, HM-only)                                                                                                                                                                                    |
| project config files | devenv `files.*` for `.beads/config.yaml` + `.beads/config.local.yaml`; HM `home.file`/`xdg` for `~/.config/bd/config.yaml`                                                                                                                                                                                                             |
| Dolt credentials     | 0600 INI at `~/.config/beads/credentials` from the repo's existing credential patterns (`lib/mcp.nix`); prefer the `BEADS_DOLT_PASSWORD` env path; never in the store                                                                                                                                                                   |
| shared-server unit   | **no reusable surface** — `services.mcp-servers` is MCP-specific and HM-only; a Dolt `sql-server` needs its own HM systemd-user unit plus a devenv `processes` counterpart (asymmetric primitives; parity note required)                                                                                                                |

Cross-cutting invariants the modules must encode:

- **`BEADS_DIR` is a runtime value.** A clone-scoped path (derived from
  `git rev-parse --git-common-dir`) cannot be baked at Nix eval, and HM-global
  Claude settings are one file for all projects — a static global value would
  force one DB across every repo. Resolution happens at invocation: wrapper,
  devenv `enterShell`, or inside the hook script itself.
- **Ownership split**: HM owns the user-global config
  (`~/.config/bd/config.yaml`), the shared-server unit, credentials, and
  machine-wide env; devenv owns project identity — prefix, `.beads/` local
  config, and assertions (`bd where`, `bd config show`
  intended-versus-effective). Team-shared `.beads/config.yaml` is touched by
  neither when a repo manages it by hand.
- **`prefix` is a required option with no default** in shared-server mode — two
  projects sharing a prefix share a DB, and the identity check fails closed but
  fails.
- **One flake owns the bd version.** The version-skew guard (newer-binary
  refusal, migration ceremony) means per-project shells must never pin a second
  `bd`; devenv modules deliver config, not binaries.
- **HM-only consumers are first-class.** A machine managed only by home-manager
  (no devenv in the consuming repo) must be able to express the full setup —
  package, config, env, hooks, permissions, server unit, and remote/push
  workflow — from HM options alone; devenv adds per-project identity and
  assertions on top, and anything devenv-only beyond that is an explicit
  exclusion with a recorded reason.

### Phase 3b — git-ref-backed Dolt remote and checkpoint workflow

`bd dolt push`/`pull` can target a Dolt remote riding an ordinary git remote on
the custom ref `refs/dolt/data` — one remote and credential for code and
work-state, invisible to normal git operations (mechanics and CAS guarantees:
`docs/beads/dolt-git-remotes.md`). The option surface should declare, per DB:
the remote URL, and a **push/checkpoint policy** (manual only / on session end /
coupled to the OD-M4 checkpoint cadence). Two facts shape the design:

- Issue state on a git ref is **not** branch-visible — no issue diffs in code
  review, ever. The options must not pretend otherwise.
- In server mode, Dolt auto-commit is off and fine-grained history vanishes
  without explicit `bd vc commit` checkpoints — so the checkpoint policy (OD-M4)
  is a prerequisite for any "history-preserving sync" claim.

Encrypted remote variants (gcrypt, crypt-mounts, self-hosted) are researched in
`docs/beads/dolt-git-remotes.md` but **deferred** behind the threat-model
decision (OD-D1) and the CAS experiments listed there — the gcrypt path in
particular is plausibly incompatible with Dolt's concurrency guarantee and must
not be offered as an option until proven.

## Resolved — do not re-derive

- **R1 — the WASM/Rust compilation question is not a beads question.** It
  belongs to codegraph (WASM tree-sitter, optional native kernel). `bd` is plain
  Go — cgo/ICU in the nixpkgs and llm-agents derivations, recorded as pure-Go in
  the upstream flake — with no parser and no WASM in any inspected derivation.
- **R2 — packaging source, re-decided 2026-08-14.** An earlier decision said
  "package via llm-agents.nix, never nixpkgs" when nixpkgs carried a stale
  pre-Dolt 0.42. nixpkgs now carries 1.0.3 with the dolt wrap, and this repo's
  standing discipline (cache-hit parity, no external-source generators) consumes
  any flake only as a pinned source anyway. Decision: **thin override of the
  nixpkgs recipe through `ourPkgs`**, tracking upstream stable releases via
  sidecar. Neither the upstream flake's outputs nor llm-agents' are consumed
  directly — llm-agents currently pins a prerelease, which is its own reason not
  to inherit it.
- **R3 — beads-mcp does read `BEADS_DIR`** (with `BEADS_DB` deprecated),
  contrary to 2026-07 research. Recorded in `docs/beads/bd-reference.md` with a
  re-verify probe (PB12); the durable lesson — per-tool MCP env surfaces must be
  confirmed, never assumed — stands.

## Open decision register

Grouped by what each decision blocks; everything not blocking a phase stays
deferred until its "needed by" moment. Owner **operator** = needs a human
ruling; owner **measure** = a probe or experiment settles it.

### Blocking phase 2 (veto window — defaults proposed, will proceed)

- **OD-P1** (operator veto): overlay defaults as specified above — dev-tools
  group, thin nixpkgs override, stable-release tracking. Proceeds as designed
  absent an objection.
- **OD-P2** (operator veto): bake telemetry-off into the overlay wrapper
  (`--set-default BD_DISABLE_METRICS=1 BD_DISABLE_EVENT_FLUSH=1`) so the
  guarantee exists below the module layer; module env still declares it for the
  MCP/hook consumers. Default: yes.
- **OD-P3** (operator): phase 2b timing — package beads-mcp alongside the
  overlay, or defer to phase 3 when its env block gets designed. Default:
  alongside (it is cheap and unblocks MCP experiments).

### Blocking phase 3 (module design)

- **OD-M1** (operator): the opinionated MVP wiring set. Which runtimes get
  default-on wiring (Claude/Codex/Copilot/Kimchi/Kiro), and which surfaces are
  on by default: MCP server vs CLI-only; prime/gate hooks; skill; rules snippet;
  permissions. This is the "opinionated setups I want to support" decision and
  shapes every module default.
- **OD-M2** (operator): default DB location posture — out-of-repo XDG
  clone-scoped (repo-invisible, survives worktree teardown, suits tracking repos
  you do not own) vs project-local `.beads/` (team-shareable,
  upstream-conventional). Both remain expressible as option values; this picks
  the default.
- **OD-M3** (operator + measure): default storage mode — embedded
  (single-writer; disqualified the moment two worktree sessions write
  concurrently) vs shared-server (one user-level Dolt server, per-project
  prefix, needs the OD-M5 unit). Input: PB2, PB7, PB8.
- **OD-M4** (operator + measure): checkpoint policy under server mode —
  auto-commit is off there, so per-write history disappears without explicit
  `bd vc commit`. Options: on issue-close, on session end (hook), gated on
  grooming operations, periodic. Blocks the server-mode option surface and phase
  3b's history claims. Input: PB8.
- **OD-M5** (operator): host platform assumption for the server unit —
  systemd-user only, or launchd parity too. Decides the HM unit form.
- **OD-M6** (operator, deferred until rework PR 7b lands — this is the table's
  naming gate): option namespace — land as `ai.programs.beads` once PR 7b
  exists; only if phase 3 must ship earlier does a standalone `beads.*`
  namespace (with a planned migration) become a real question.

### Deferred (nothing before phase 3b depends on these; revisit when a consumer arrives)

- **OD-D1** (operator): encrypted-remote threat model (adversary set, metadata
  sensitivity, per-repo scope). Blocks only the encrypted variants of 3b.
- **OD-D2** (measure): session/turn linking carrier — metadata bag vs notes vs
  comments; the correlation rule requires explicit `bead:<id>` tokens in
  session-visible text. Input: PB1.
- **OD-D3** (measure): dedup layer shape — adopt emBEADings vs rebuild on
  beads-sdk vs FULLTEXT-only. Sequencing rule: measure the agent
  check-before-file rate first; if ~zero, the create-time gate is the fix and
  search quality is moot. Input: PB9.
- **OD-D4** (measure): structure enforcement for formula-stamped subgraphs
  (beads _formulas_ stamp templated subgraphs of issues when "poured"; whether
  the stamped structure is re-validated afterwards is unverified). Input: PB6.
- **OD-D5** (operator): Kiro integration depth — upstream `bd setup` has no kiro
  target, so Kiro wiring is hand-rolled steering + hooks; decide how far past
  the MVP bar to go.

## Probe queue

All probes: throwaway DB under `/tmp`, `BEADS_DIR` set (except where a probe
explicitly tests the unset path), `--stealth`; ~5 minutes each; batchable in one
session against the phase 2 package. Feeds noted.

- **PB1** — metadata bag: arbitrary key settable via CLI? values readable back
  via `bd show --json` / JSONL round-trip? → OD-D2, and the metadata filter-only
  rule in `docs/beads/bd-reference.md`.
- **PB2** — shared-server duplicate-prefix connect: confirm documented refusal,
  capture the error shape. → OD-M3, module assertion text.
- **PB3** — `bd where` from a linked git worktree with `BEADS_DIR` unset:
  correct main-repo workspace reported? → devenv assertion viability.
- **PB4** — `bd config show --json`: provenance field shape stable and
  parseable? → the intended-versus-effective assertion task.
- **PB5** — custom issue types: `bd create -t <custom>` accepted? (A 2026-03
  defect had `bd types` listing and `bd update` accepting a type that
  `bd create` rejected.) → taxonomy expressibility.
- **PB6** — formula enforcement: pour a formula, create a bare violating child
  under the stamped epic — accepted? → OD-D4.
- **PB7** — daemon existence: observe processes around bd invocations;
  `BD_NO_DAEMON` semantics; any background writer? → OD-M3 (second-writer risk).
- **PB8** — server-mode auto-commit empirics: confirm off-by-default, resolve
  the flag-vs-config default discrepancy, characterize `bd vc commit`
  granularity and Dolt history shape after mixed writes. → OD-M3, OD-M4.
- **PB9** — emBEADings `neighbors` quality spot-check once a real backlog is
  seeded (≥30 issues): does the static model catch known paraphrase pairs? →
  OD-D3.
- **PB10** — residual v1.1.0 verification list: `--type decision` as an
  inclusion filter; `created_at` monotonicity; `supersedes`/`relates-to` link
  types; `--defer` release-flip with `no-git-ops` + auto-commit preconditions on
  an out-of-repo DB; the env-unset fallback (does `bd` without `BEADS_DIR`
  actually reach the repo, and does the failsafe `no-git-ops` placement hold);
  timer-gate batch semantics; Dolt session-branches as an isolation mechanism;
  the FULLTEXT ID-tokenization hazard. → `docs/beads/bd-reference.md` unverified
  tags.
- **PB11** — version-skew guard: does an older bd actually refuse a newer-schema
  DB, and with what error? → the one-flake-owns-the-version rule.
- **PB12** — beads-mcp env surface at the pinned PyPI version: confirm which of
  `BEADS_DIR`/`BEADS_DB`/`BEADS_WORKING_DIR` the server reads and their
  precedence, and the bd-version-skew tolerance of a non-lockstep pairing. →
  phase 2b env block, R3.
- **Remote experiments** — the six CAS/encryption experiments in
  `docs/beads/dolt-git-remotes.md` (gcrypt race first). → phase 3b encrypted
  variants.

## Validation (phases 2–3)

- `nix build .#beads --max-jobs 1` and inspect `bin/` for exactly one wrapped
  `bd` (`.bd-wrapped` present, no double wrap); `bd --version` matches the
  sidecar.
- `nix flake check` — structural gates (`update-targets-parity`,
  `cache-hit-parity`, `go-floor-drift` via `passthru.goFloor`) all discover the
  new package without manual test edits.
- Update-pipeline dry run: the sweep's update script rewrites the sidecar and
  restores `vendorHash`/`goFloor` (a no-op run costs ~1s).
- Module eval: HM and devenv module fixtures in `checks/module-eval.nix` once
  phase 3 lands; parity per `checks/options-doc.nix`.
- Darwin builds are a CI observation (`build (aarch64-darwin)`), never a local
  claim.

## Maintenance

This plan and its three companions carry `Last verified` markers. Any change to
the overlay, the module surface, or an upstream fact a companion records must
update the affected document in the same commit — a stale companion is worse
than none. When the rework's PR 7b lands, revisit OD-M6 and re-cite the option
paths in the phase 3 table.
