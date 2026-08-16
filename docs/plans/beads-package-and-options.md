# Beads: overlay package and `ai.*` option surface

> **Status: IN PROGRESS** — phase 2 is implemented and held in #1011; phase 3
> remains gated. Created 2026-08-14; updated 2026-08-16 after the normalized
> program factory landed in #1024. Companion references, synthesized from prior
> research sessions and re-verified where marked: `docs/beads/bd-reference.md`
> (the tool), `docs/beads/dolt-git-remotes.md` (sync/remote mechanics),
> `docs/beads/ecosystem.md` (integrations and prior art). Facts in this plan
> that duplicate a companion are deliberate summaries — the companion is
> authoritative; update both in the same commit.

## Goal

Adopt beads (`bd`, the Dolt-backed graph issue tracker for coding agents) as a
first-class citizen of this repo:

1. **Overlay package** — `pkgs.ai.devTools.beads` on the standard update
   pipeline (phase 2, implemented and held in #1011).
2. **Option surface** — a future `ai.programs.beads` convenience tree with
   HM/devenv parity for normalized declarations, plus a devenv-only operational
   lifecycle for server, initialization, credentials, and publication (phase 3,
   gated).
3. **Git-ref-backed sync** — support a Dolt remote riding an ordinary git remote
   (`refs/dolt/data`) through the devenv operational lifecycle, with an explicit
   checkpoint/push workflow (phase 3, partially gated).

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
session-start hooks, env, permissions) is declared through normalized `ai.*`
surfaces where supported; the stateful lifecycle remains a devenv concern.
Concretely:

- Init only ever as `bd init --quiet --skip-agents --skip-hooks` (or
  `--stealth`), with `no-git-ops: true` — and the `no-git-ops` config is
  **load-bearing, not belt-and-suspenders**: `BEADS_DIR` bypasses git-repo
  discovery only when the env var is present in an invocation, and `bd` runs
  with cwd = repo root, so the config must live where `bd` reads it _without_
  the env var (project-local `.beads/config.yaml` or the user-global config).
  Details in `docs/beads/bd-reference.md`.
- Telemetry off is a hard requirement (`BD_DISABLE_EVENT_FLUSH=1`,
  `BD_DISABLE_METRICS=1`, `DOLT_DISABLE_EVENT_FLUSH=1`).
- Hooks and wrappers that cannot resolve their workspace must **emit a signal**,
  never silently no-op — an env-delivery failure must not present as "beads just
  never primes."

## Phases and gating

| Phase | Deliverable                                                  | State / gate                                         |
| ----- | ------------------------------------------------------------ | ---------------------------------------------------- |
| 1     | This document set                                            | Complete                                             |
| 2     | `overlays/dev-tools/beads.nix` + registrations               | Implemented and held in #1011                        |
| 2b    | `overlays/mcp-servers/beads-mcp.nix`                         | OD-P3 (timing); technically unblocked                |
| 3     | normalized convenience + devenv-only operational module      | OD-M1..M5, probes; namespace gate satisfied by #1024 |
| 3b    | Git-ref Dolt remote options + qualified checkpoint/push flow | OD-M4; encrypted variants additionally OD-D1         |

Phase 3's namespace question is settled: #1024 shipped `ai.programs.<pkg>` /
`ai.<runtime>.programs.<pkg>` with generated per-leaf runtime overrides. Beads'
options should land in that shape. The remaining phase-3 gates are the operator
decisions and probes named above, not an interface migration.

## Phase 2 — the overlay (implemented and held)

Verified 2026-08-14: this repo's pinned nixpkgs already carries `beads` 1.0.3
(`pkgs/by-name/be/beads/package.nix` — buildGoModule, ICU, MIT,
`mainProgram = "bd"`, and a `postInstall` wrapping `dolt` onto PATH) and `dolt`
(2.2.3 at the 2026-08 pin, Apache-2.0). So the overlay is a **thin override of
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
  the sweep follows **stable releases** and currently pins v1.2.2. Bootstrap:
  the overlay reads the sidecar at eval time with no fallback for
  `version`/`src`, so commit a minimal seed sidecar first (placeholder hashes
  are fine — `vendorHash` falls back through the fixer), run the update script
  once to prefetch the real hashes and let `fixVendorHash`/`fixGoFloor` restore
  the derived keys, then commit the regenerated file. Hashes come from tooling,
  never hand-pasted.
- The Dolt PATH wrap is **inherited from the nixpkgs recipe** and is extended at
  one anchored seam with `lib.replaceString`; evaluation fails if the upstream
  `postInstall` shape moves. Do not add a second `wrapProgram` (double-wrapping
  is the trap; check with
  `ls -a $(nix build .#beads --no-link --print-out-paths)/bin` for a single
  `.bd-wrapped`). The extended invocation uses `--set` for
  `BD_DISABLE_EVENT_FLUSH`, `BD_DISABLE_METRICS`, and
  `DOLT_DISABLE_EVENT_FLUSH`, preserving the inherited Dolt PATH prefix and all
  other upstream installation logic.
- Registrations, all alphabetically placed within their files:
  `config/cache-hit-parity-targets.nix`
  (`consumerPath = ["ai" "devTools" "beads"]`), `config/update-targets.nix`
  (binary row, `--override-filename overlays/dev-tools/beads.nix`),
  `dev/data.nix` (`devToolDescriptions` — root README is generated; regenerate
  via `devenv tasks run --mode before generate:all`), `overlays/README.md`
  (hand-maintained index), `overlays/default.nix` (`devToolDrvs`).
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
(`sympy-mcp.nix` for build shape only — its main-tracking update row does NOT
transfer), baking `BEADS_PATH` to the overlay's `bd`. **Version tracking:**
beads-mcp lives in the same `gastownhall/beads` monorepo
(`integrations/beads-mcp/`), so build it **from the bd sidecar's pinned source
tag** — one source of truth, the same stable line as bd, no second
update-targets row following main. Whether `update-targets-parity` demands a row
anyway is an implementation detail to settle in 2b; if it does, the row must be
a no-op deferring to the bd sidecar. Registrations mirror phase 2's list with
the mcp-servers group spellings
(`consumerPath = ["ai" "mcpServers" "beads-mcp"]`, `mcpServerDrvs`,
`mcpServerDescriptions`). bd-version skew is bounded by bd's own schema guard
(PB12 verifies). Its env surface (`BEADS_DIR` supported, `BEADS_DB` deprecated —
note this _refutes_ older research; see `docs/beads/bd-reference.md`) must be
re-verified at the pinned version when the module wires the env block (PB12).

## Phase 3 — the option surface (gated)

The future convenience layer is `ai.programs.beads`, with generated runtime
leaves and HM/devenv parity for its normalized declarations. Stateful operation
belongs only in `packages/beads/modules/devenv/`: server lifecycle,
initialization, credentials, mutation serialization, and publication are not an
HM surface. The target bindings below follow the coordinated
normalized-interface boundary; rows explicitly identify present gaps:

| beads surface        | target factory mechanism                                                                                                                                                                     |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `bd` on PATH         | ordinary HM/devenv package primitives outside the normalized program tree; every consumer uses this flake's `pkgs.ai.devTools.beads`, never a second pin                                     |
| beads-mcp            | normalized MCP/settings pools, lowered by each runtime transformer to its supported native representation; unsupported runtimes are explicit exclusions                                      |
| session-start prime  | normalized typed hooks, lowered by each runtime transformer; a missing native event is an explicit exclusion rather than a Beads-specific workaround                                         |
| timer-gate check     | same normalized hook surface as prime (`bd gate check`)                                                                                                                                      |
| onboard snippet      | normalized instructions pool                                                                                                                                                                 |
| skill                | normalized skills pool                                                                                                                                                                       |
| env / telemetry-off  | normalized settings/environment pools; fill normalization gaps instead of adding Beads-specific native settings                                                                              |
| permissions          | normalized typed permissions pool with explicit per-runtime exclusions                                                                                                                       |
| project config files | existing devenv file primitives; #983's future `ai.<runtime>.files` native escape hatch is not an MVP dependency                                                                             |
| Dolt credentials     | devenv-managed runtime secret material, never the Nix store; prefer `BEADS_DOLT_PASSWORD`. Never put secrets in database-level config (`bd config set`), because it replicates to the remote |
| shared-server unit   | devenv process lifecycle only. Bind loopback-only by default, pin auth explicitly, and take `dolt` from the same pinned nixpkgs as the wrapper — one Dolt provenance everywhere              |

Cross-cutting invariants the modules must encode:

- **Normalized boundary**: the future convenience layer is `ai.programs.beads`,
  never `ai.beads`. It composes normalized hooks, skills, instructions,
  MCP/settings, and typed pools; runtime transformers perform supported native
  lowering. `nativeSettings` remains the native lowering and escape layer, not a
  merged normalized/native attribute set. Prefer filling a normalization gap
  over adding a Beads-specific native workaround.
- **`BEADS_DIR` is a runtime value.** A clone-scoped path (derived from
  `git rev-parse --git-common-dir`) cannot be baked at Nix eval. Resolution
  happens in the devenv operational lifecycle or inside its generated commands.
- **Operational ownership**: devenv owns server lifecycle, project identity,
  prefix, local config, credentials, mutation serialization, publication, and
  assertions (`bd where`, `bd config show` intended-versus-effective). HM/devenv
  parity applies only to the future normalized `ai.programs.beads` convenience
  declarations; it does not make the operational lifecycle an HM surface.
  Team-shared `.beads/config.yaml` is untouched when a repository manages it by
  hand.
- **`prefix` is a required option with no default** in shared-server mode — two
  projects sharing a prefix share a DB, and the identity check fails closed but
  fails.
- **One flake owns the bd version.** The version-skew guard (newer-binary
  refusal, migration ceremony) means per-project shells must never pin a second
  `bd`.
- **No HM operational fallback.** A Home Manager consumer may use the future
  normalized convenience declarations, but the shared server, initialization,
  credentials, and checkpoint/push/recovery workflow require the devenv module.
- **Until phase 3b lands a remote, every DB is a single local copy** of what the
  reference calls a design-doc corpus, and a true backup is only `bd backup` /
  `bd dolt push`. Adopting phase 3 early means accepting that window; the
  interim stopgap is a scheduled `bd export --all` (lossy-but-usable, documented
  in the reference).

### Phase 3b — git-ref-backed Dolt remote and checkpoint workflow

`bd dolt push`/`pull` can target a Dolt remote riding an ordinary git remote on
the custom ref `refs/dolt/data` — one remote and credential for code and
work-state, invisible to normal git operations (mechanics and CAS guarantees:
`docs/beads/dolt-git-remotes.md`). The option surface should declare, per DB:
the remote URL, a **push/checkpoint policy** (manual only / on session end /
coupled to the OD-M4 checkpoint cadence), and a **pull posture** — the
divergent-history pull behavior is uncharacterized (see the companion's
experiment list), so multi-machine designs must not assume pulls are
conflict-free. Two facts shape the design:

- Issue state on a git ref is **not** branch-visible — no issue diffs in code
  review, ever. The options must not pretend otherwise.
- In server mode, Dolt auto-commit is off and fine-grained history vanishes
  without explicit `bd vc commit` checkpoints — so the checkpoint policy (OD-M4)
  is a prerequisite for any "history-preserving sync" claim.

Encrypted remote variants (gcrypt, crypt-mounts, self-hosted) are researched in
`docs/beads/dolt-git-remotes.md` but **deferred** behind the threat-model
decision (OD-D1) and the CAS experiments listed there — the gcrypt path in
particular is plausibly incompatible with Dolt's concurrency guarantee and must
not be offered as an option until proven. **Until OD-D1 is answered, configuring
any third-party remote means plaintext work-state on that host — that is the
recorded pre-OD-D1 default, a conscious accept and not an oversight.**

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

### Blocking phase 2 (veto window — defaults proposed, will proceed; the window is review of this PR and closes on its merge)

- **OD-P1** (operator veto): overlay defaults as specified above — dev-tools
  group, thin nixpkgs override, stable-release tracking. Proceeds as designed
  absent an objection.
- **OD-P2 — implemented:** the overlay extends the inherited single wrapper at
  an anchored `wrapProgram` token and uses `--set` for
  `BD_DISABLE_EVENT_FLUSH=1`, `BD_DISABLE_METRICS=1`, and
  `DOLT_DISABLE_EVENT_FLUSH=1`. Evaluation fails if the upstream seam moves; the
  implementation preserves the rest of `postInstall` and never adds a second
  wrapper.
- **OD-P3** (operator): phase 2b timing — package beads-mcp alongside the
  overlay, or defer to phase 3 when its env block gets designed. Default:
  alongside (it is cheap and unblocks MCP experiments).
- **OD-P4** (operator veto): sweep posture versus schema migrations. The 4x/day
  sidecar sweep lands bd bumps unattended, but the reference records that
  crossing a schema migration on a shared DB is a manual multi-clone ceremony
  and that an older bd refuses a newer-schema DB — an unattended bump is a
  one-way door once DBs exist. Default: sweep freely through phase 2 (no DBs
  exist yet); **before phase 3 ships**, revisit with PB13's findings and pick
  between migration-aware sweep handling and pinned manual bumps.

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
  the default. Sharp edge of the XDG default: identity is keyed to the clone
  path, so **moving or renaming the clone silently orphans the DB** — bd
  resolves a fresh empty workspace with no error. The decision input must
  include a relink/migration note (or `bd where`-based detection) for that case.
- **OD-M3** (operator + measure): default storage mode — embedded
  (single-writer; disqualified the moment two worktree sessions write
  concurrently) vs shared-server (one user-level Dolt server, per-project
  prefix, needs the OD-M5 unit). Input: PB2, PB7, PB8.
- **OD-M4** (operator + measure): checkpoint policy under server mode —
  auto-commit is off there, so per-write history disappears without explicit
  `bd vc commit`. Options: on issue-close, on session end (hook), gated on
  grooming operations, periodic. Blocks the server-mode option surface and phase
  3b's history claims. Input: PB8.
- **OD-M5** (operator): host-platform scope for the devenv server process. The
  process binds loopback-only by default and pins auth (see the shared-server
  row); this decision does not create an HM lifecycle surface.
- **OD-M6 — resolved by #1024:** the option namespace is `ai.programs.beads`,
  with generated per-runtime leaves under `ai.<runtime>.programs.beads`. Do not
  introduce a standalone `beads.*` namespace.

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
- **OD-D5** (operator): Kiro integration depth. The pinned stable v1.2.2 exposes
  upstream Kiro setup, but the pure-data-engine discipline still declares Kiro
  wiring through normalized repository surfaces. Decide how far past the MVP bar
  to go.
- **OD-D6** (operator): teardown and data lifecycle. Disabling the modules
  leaves residue nothing currently cleans up: the shared-server data dir
  (`~/.beads/shared-server/`, every project's DB), project `.beads/` and
  out-of-repo XDG workspaces, the 0600 credentials INI, and — hardest to
  rediscover — `refs/dolt/data` parked on git remotes, invisible to normal git
  operations by design. Also the retention posture (`bd admin compact` + Dolt
  GC) at the module level. Decide per surface what the modules clean up versus
  document as manual.

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
- **PB5** — custom issue types: `bd create -t <custom>` accepted? (Premise is
  carried, unverified research: a reported 2026-03 defect had `bd types` listing
  and `bd update` accepting a type that `bd create` rejected — see the
  reference's carried-unverified list.) → taxonomy expressibility.
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
  whether `bd init --skip-hooks` really still runs `git init` + commit +
  `git config beads.role`; timer-gate batch semantics; Dolt session-branches as
  an isolation mechanism; the FULLTEXT ID-tokenization hazard. →
  `docs/beads/bd-reference.md` unverified tags.
- **PB11** — version-skew guard: does an older bd actually refuse a newer-schema
  DB, and with what error? → the one-flake-owns-the-version rule.
- **PB12** — beads-mcp env surface at the pinned version: confirm which of
  `BEADS_DIR`/`BEADS_DB`/`BEADS_WORKING_DIR` the server reads and their
  precedence, and the bd-version-skew tolerance of a non-lockstep pairing. →
  phase 2b env block, R3.
- **PB13** — migration and rollback: what `bd migrate` actually does, whether
  any downgrade path exists, and whether `bd export --all` → fresh init →
  `bd import` recovers across a schema-version boundary. → OD-P4, the
  one-way-door risk.
- **PB14** — dolt hygiene: does the pinned `dolt` emit metrics/events by default
  and what disables them (dolt historically ships DoltHub usage metrics with its
  own off switch); and bd's tolerance for dolt version skew (wrap vs server unit
  must share one provenance either way). → OD-P2's guarantee actually holding,
  the shared-server unit design.
- **Remote experiments** — the CAS/encryption experiments in
  `docs/beads/dolt-git-remotes.md` (the cheap URL-passthrough check first — it
  is a prerequisite of the gcrypt race — then the race, then the rest). → phase
  3b.

## Validation (phases 2–3)

- `nix build .#beads --max-jobs 1` and inspect `bin/` for exactly one wrapped
  `bd` (`.bd-wrapped` present, no double wrap — the OD-P2 bake extends the one
  wrap in place, so the count stays one); `bd --version` matches the sidecar. If
  OD-P2 landed, also assert the baked env: run the wrapped `bd` under `env -i`
  and confirm all three telemetry/no-flush variables are set (the wrap-count
  check alone cannot catch a misspelled `--set`).
- `nix flake check` — structural gates (`update-targets-parity`,
  `cache-hit-parity`, `go-floor-drift` via `passthru.goFloor`) all discover the
  new package without manual test edits.
- Update-pipeline dry run: the sweep's update script rewrites the sidecar and
  restores `vendorHash`/`goFloor` (a no-op run costs ~1s).
- Module eval: HM and devenv fixtures for the future normalized convenience
  tree, plus devenv-only lifecycle fixtures, once phase 3 lands; convenience
  parity per `checks/options-doc.nix`.
- Darwin builds are a CI observation (`build (aarch64-darwin)`), never a local
  claim.

## Maintenance

This plan and its three companions carry `Last verified` markers. Any change to
the overlay, the module surface, or an upstream fact a companion records must
update the affected document in the same commit — a stale companion is worse
than none. If the normalized program factory changes, update the resolved OD-M6
paths and the phase 3 table in the same commit.
