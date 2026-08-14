# bd (beads) — tool reference

> **Last verified:** 2026-08-14 against `github.com/gastownhall/beads` main and
> the release line through v1.2.1, plus the nixpkgs and `numtide/llm-agents.nix`
> derivations. Companion documents: `dolt-git-remotes.md` (remote/sync
> mechanics), `ecosystem.md` (integrations and prior art). The consuming plan is
> `docs/plans/beads-package-and-options.md`.
>
> **Provenance tags.** `[measured @1.1.0]` — observed by running the real `bd`
> v1.1.0 binary during a hands-on evaluation (2026-07). `[upstream]` — read from
> upstream docs or source at the date above. `[unverified]` — carried from
> research that never executed the binary; quarantine until probed (the plan's
> probe queue tracks the load-bearing ones). Claims can go stale in either
> direction; re-verify against the pinned version before building on a
> load-bearing one.

## What beads is

Beads is a distributed graph issue tracker built for coding agents: a `bd` CLI
over a dependency DAG of issues, with `bd ready` / `bd blocked` as the
work-queue primitives. MIT-licensed, no web UI by design. Storage is **Dolt** (a
version-controlled SQL database with cell-level merge and native branching);
beads migrated off JSONL/SQLite, so pre-migration writeups are stale on storage
and sync. Issue IDs are hash-based (`bd-a1b2`) to avoid merge collisions across
concurrent agents and branches. Sync is `bd dolt push` / `bd dolt pull` against
a Dolt remote. Old closed issues can be compacted ("memory decay") via
`bd admin compact --days N` plus Dolt garbage collection. `[upstream]`

There is **no pluggable storage backend** — beads embeds Dolt specifically; the
MySQL dialect is an implementation detail that only surfaces through `bd sql`.
Doltgres (the Postgres-flavored build; 1.0 announced 2026-06, released 2026-08)
shares the storage engine, but dialect preference should not drive any decision
here. `[upstream]`

The intended usage pattern includes `bd remember` for persistent project memory,
explicitly replacing MEMORY.md-style files — so a beads DB accumulates design
reasoning, not just task titles. Treat its confidentiality closer to a
design-doc corpus than an issue tracker (see `dolt-git-remotes.md`).
`[upstream]`

## Versions and packaging state (2026-08-14)

- **Upstream**: latest stable release **v1.1.2** (2026-07-26). **v1.2.1**
  (2026-08-11) exists but is marked **prerelease**; v1.2.0 appears tag-only (no
  release object found; unconfirmed). `[upstream]`
- **nixpkgs**: `beads` **1.0.3** on nixos-unstable (`pkgs/by-name/be/beads/`),
  absent from the 25.11 release. `buildGoModule`, `subPackages = ["cmd/bd"]`,
  `buildInputs = [icu]`, MIT, `mainProgram = "bd"`, and a `postInstall` that
  wraps `dolt` onto `bd`'s PATH. One test is skipped everywhere
  (`TestCheckMetadataVersionTracking`), a second on Darwin
  (`TestCleanupMergeArtifacts_CommandInjectionPrevention`), and the recipe sets
  `__darwinAllowLocalNetworking`. `[upstream]`
- **Upstream flake**: pins `nixos-25.11`, requires `buildGo126Module`, exposes
  `beads-unwrapped` via `overlays.default` with a documented `vendorHash`
  override recipe. Its wrapper adds shell completions and sets
  `BD_DISABLE_METRICS=1` / `BD_DISABLE_EVENT_FLUSH=1` (install-phase scope, so
  completion generation touches no DB), but does **not** wrap dolt. `[upstream]`
- **`numtide/llm-agents.nix`**: its own derivation pinning **v1.2.1** (the
  prerelease), `buildGoModule.override { go = go-bin; }`, `CGO_ENABLED=1` with
  explicit ICU flags (the `go-icu-regex` cgo directives carry no
  `#cgo pkg-config:` line), `doCheck = false`, and a dolt PATH wrap. It also
  ships `beads-rust` (an unrelated single-maintainer Rust reimplementation) and
  `beads-viewer`. `[upstream]`
- **dolt**: a separate binary, required for the server modes;
  `bd dolt push/pull` shells out to it. nixpkgs carries it (2.2.3 at this repo's
  2026-08 pin; Apache-2.0). `[upstream]`
- **Compilation**: `bd` is plain Go. The nixpkgs and llm-agents derivations
  build with cgo/ICU (verified at the date above); the upstream flake's own
  derivation was earlier recorded as a pure-Go build (`gms_pure_go` tag, no cgo)
  and was not re-inspected. No parser toolchain and no WASM appear in any
  inspected derivation — any WASM-versus-native-parser packaging concern belongs
  to codegraph (WASM tree-sitter with an optional native kernel), not to beads.
  `[upstream]`

**Version-skew ceremony.** `bd` refuses to open a DB created by a newer binary
`[unverified]`. Crossing a schema migration on a remote-backed DB means exactly
one designated clone runs `bd migrate` + `bd dolt push` while all others
`bd bootstrap` `[upstream]`. Direct packaging implication: on any shared DB, a
single pinned `bd` version must be authoritative machine-wide — one flake owns
the binary; per-project shells pin config, never a second binary.

## Config surface

Two config systems with a hard split:

- **YAML (Viper).** Search order, later overriding earlier:
  `~/.beads/config.yaml` (legacy) → `~/.config/bd/config.yaml` →
  `<repo>/.beads/config.yaml` → `$BEADS_DIR/config.yaml`; a
  `.beads/config.local.yaml` is merged last (machine-local, uncommitted).
  Overall precedence: flags → env → YAML → defaults. Declarable namespaces:
  `ai.*`, `backup.*`, `directory.*`, `dolt.*`, `export.*`,
  `external_projects.*`, `federation.*`, `git.*`, `hierarchy.*`, `list.*`,
  `metrics.*`, `repos.*`, `routing.*`, `sync.*`, `validation.*`, plus named
  scalars. Storage mode, ports, shared-server, hydration, routing, validation
  strictness, and metrics-off are all YAML-declarable. `[upstream]`
- **Database config.** Project-level state (external-tracker credentials, status
  maps) lives in Dolt itself, set via `bd config set`, and travels with
  `bd dolt push`. It has **no env override**, so it is unreachable from Nix by
  construction — imperative post-init only. Do not build options for it.
  `[upstream]`

`bd config show` prints each key's effective value **plus its source**, which
makes an intended-versus-effective assertion task possible; the JSON shape's
stability is `[unverified]`. `bd config get` reads individual keys —
`dolt.auto-commit` and `no-git-ops` were exercised this way `[measured @1.1.0]`.
The YAML config is a working-tree file and is **not** included in `bd export`;
posture config must be re-applied after any rebuild from JSONL
`[measured @1.1.0]`.

**Secrets.** Dolt-server credentials live in an INI file at
`~/.config/beads/credentials` (directory `beads`, **not** `bd`), sections keyed
`[host:port]`, with a stderr warning when the file is group/world-readable.
Resolution order: `BEADS_DOLT_PASSWORD` → credentials file → empty. Keys
matching `api_key|secret|token|password` are **refused** on a git-tracked
`config.yaml` unless `--force-git-tracked`. `[upstream]`

## Init residue and the pure-data-engine posture

`bd init` self-wires: it writes an AGENTS.md, installs git hooks, and writes
`.beads/.gitignore`. It also runs `git init` + an initial commit +
`git config beads.role` **even with `--skip-hooks`** `[measured @1.1.0]` —
suppressing that requires the `no-git-ops` config, an out-of-tree DB, or
`--stealth`. The disable surface:

- `--quiet --skip-agents --skip-hooks` — suppress the individual writes;
  `--stealth` = all three plus `no-git-ops: true`. `[upstream]`
- `bd onboard` **prints** the agent-instructions snippet instead of writing it,
  which is what makes declarative placement possible. `[upstream]`
- `bd setup` at **v1.1.2** (the pinned stable line) has **no kiro target**;
  upstream added `bd setup kiro` by v1.2.1, whose target list is much longer
  (cursor, claude, copilot, gemini, aider, factory, codex, mux, opencode, junie,
  kiro, windsurf, cody, kilocode). Version-scope any claim about setup targets.
  `[upstream]`
- Git hooks, when wanted at all, are thin shims calling `bd hooks run <name>`; a
  declarative hook manager can invoke that directly and skip bd's installer.
  `[upstream]`
- Telemetry kill switches: `BD_DISABLE_METRICS=1`, `BD_DISABLE_EVENT_FLUSH=1`.
  `[upstream]`

Storage layout under a project-local workspace: `.beads/config.yaml` (track),
`.beads/metadata.json` (track), `.beads/.gitignore` (bd-written),
`.beads/embeddeddolt/` and `.beads/dolt/` (never track). `[upstream]`

## Storage modes

- **Embedded** (default): single-writer, file-lock enforced; the violation
  symptom is `database is locked` and the documented fix is server mode.
  Worktrees **share one `.beads` workspace by design**, so two agent sessions in
  two worktrees are two writers on one lock — multi-session use disqualifies
  embedded mode. `[upstream]`
- **Server**: an external `dolt sql-server`; default port 3307. `[upstream]`
- **Shared-server**: one Dolt server at `~/.beads/shared-server/`, default port
  **3308** (3307 is reserved for the plain server, 3306 for real MySQL), with a
  per-project database selected by **prefix**. Enable via
  `dolt.shared-server: true`, `BEADS_DOLT_SHARED_SERVER=1`, or
  `bd init --prefix X --shared-server`. Two projects sharing a prefix share a
  DB; an identity check **refuses the connection** (fails safe, but fails) — the
  exact error shape is `[unverified]`. `[upstream]`

**The auto-commit flip is the load-bearing cost.** Upstream documents the config
default as **on for embedded, off for server** (under concurrency, a Dolt commit
per write produces `database is read only` errors). With auto-commit on, every
mutation is an immediate, durable Dolt history commit `[measured @1.1.0]`; with
it off, fine-grained history vanishes unless explicit `bd vc commit` checkpoints
are issued, and a crash window opens between write and commit. Note an internal
doc inconsistency: the CLI reference states the `--dolt-auto-commit` flag
default as plain `off` and documents a third `batch` mode; which statement wins
is `[unverified]`. Any "git-like history" requirement therefore hangs on an
explicit **checkpoint policy** in server mode — that is an open decision in the
plan, not a settled default.

**Split-brain**: a stale `.beads/dolt-server.port` file versus an env-pointed
managed server yields two truths for one DB name; `bd doctor` warns but only
diagnostically. Machine-wide env pinning of the port makes the stale file
unreachable. `[upstream]`

**Daemon residue**: `BD_NO_DAEMON` appears in the config table and
`BEADS_NO_DAEMON=1` in a third-party tmux plugin, but the current docs tree
contains no daemon documentation — plausibly a SQLite-era mechanism superseded
by the storage modes. It matters because a stray daemon would be a second
writer. `[unverified]`

## Workspace resolution and isolation

Resolution: `BEADS_DIR` if set, else the main repo's `.beads`; linked worktrees
follow the same chain (shared workspace, no duplication). `bd where` is the
authoritative active-workspace check — better than testing for `./.beads`, which
worktrees legitimately lack. `[upstream]`

`BEADS_DIR` is a full escape hatch: an external workspace shared across
checkouts, with `bd dolt push/pull` targeting it; combined with `--stealth` it
yields a repo-invisible tracker. **The subtlety that keeps git-ops off a repo:**
`BEADS_DIR` bypasses git-repo discovery, but `bd` still _runs_ with cwd = repo
root (hooks and agent shell calls both do), so the git-ops protection is
contingent on the env var being present in **every** invocation. If it is
missing, `bd` falls back to cwd discovery and finds the repo. Therefore
`no-git-ops` stays load-bearing — and its config must live somewhere `bd` reads
**without** the env var (a project-local `.beads/config.yaml` or the user-global
config), not only inside the external dir that `bd` never reads when the var is
unset. Provenance is split: operating on an out-of-repo DB with the env var set
is `[measured @1.1.0]`; the env-unset fallback actually performing git-ops
against the repo — and therefore the exact failsafe-placement requirement — is
`[unverified]` design reasoning. Prove both paths before relying on containment
(the plan's probe queue covers this). Even then, `bd` may still _read_ cwd git
state (e.g. the branch, for protected-branch logic) — reads are harmless; do not
misread them as a containment failure.

There is **no ACL or permission model**. Four mechanisms exist, all YAML
path-lists — whatever is listed is reachable `[upstream]`:

1. **Hydration** (aggregate reads): `repos.additional`, optional
   `repos.primary`; `bd list` / `bd ready` unify across repos.
2. **Routing** (write placement):
   `routing.mode: auto|maintainer|contributor|explicit`; maintainer default `.`,
   contributor default `~/.beads-planning`; auto-detection keys off the
   git-remote shape. Every issue carries `source_repo`, and `discovered-from`
   children **inherit the parent's `source_repo`** — deliberate, so tangents
   stay in the planning repo instead of leaking into the code repo.
   `--repo <path>` overrides per command.
3. **`external_projects`** (name→path map): enables cross-DB
   `bd dep add A B --type blocks`; hierarchy can span databases.
4. **Federation** (peer sync): DoltHub/S3/GCS/file/HTTPS/SSH/git-SSH endpoints,
   AES-256 local credential encryption, sovereignty tiers T1–T4, bidirectional
   `bd federation sync`; conflicts pause unless `--strategy ours|theirs`. Wrong
   altitude for a single workstation — shared-server covers that case.

Conditional per-agent-class access is achieved with separate `BEADS_DIR`-scoped
environments, not a beads feature.

## Search and query surface

Three native tiers `[upstream]`:

1. **`bd search`** — title+ID by default, ID-like queries take a fast
   exact/prefix path; rich flag set (`--desc-contains`, `--notes-contains`,
   `--label`/`--label-any`, `--type`, `--priority-min/max`, date bounds on
   created/updated/closed, `--metadata-field k=v`, `--has-metadata-key`,
   `--sort`, `--status all`).
2. **`bd query`** — a DSL with comparison operators, `AND OR NOT`, parens, ~20
   fields including contains-matching on title/description/notes, ID wildcards,
   and relative/natural dates; `--parse-only` dumps the AST.
3. **`bd sql`** — raw SQL including destructive statements, bypassing the
   storage layer (upstream warns); `--csv`/`--json`.

**The ceiling**: all text matching in all tiers is case-insensitive substring
`contains` (`LIKE '%x%'` semantics) — no relevance ranking, no stemming, no
fuzzy, no semantic retrieval. Paraphrase-level duplicate detection is blind
("JWT expiry" never matches "token refresh"). Latent capacity: Dolt supports
MySQL-style `FULLTEXT` + `MATCH ... AGAINST`, and beads declares no FULLTEXT
index — a middle option is adding one via a `bd sql` migration, with no new
process. A known hazard: FULLTEXT tokenization can match issue-ID-like strings;
exact-label/ID queries are immune. `[unverified]` `bd duplicates` provides a
native exact floor (content hash over title+description+design+acceptance
criteria, `--auto-merge --dry-run`) — identical text only, zero paraphrase. See
`ecosystem.md` for the semantic layer above this.

## Measured CLI behavior (v1.1.0 hands-on)

All items in this section are `[measured @1.1.0]` unless marked otherwise.

- **Issue model**: types include `task`, `epic`, and an ADR-style `decision`
  (`--type decision`); `bd create --parent <id>` yields dotted child IDs. Fields
  exercised: title, description, `notes`, labels, status (open / `in_progress` /
  closed), `close_reason` (`bd close --reason`), `defer_until`, `priority`,
  `created_at`, `issue_type`, parent, metadata. Native link types `supersedes` /
  `relates-to` are reported by research but `[unverified]`. Creation of the
  three types is measured; `--type` as an _inclusion filter_ on `bd list` is
  `[unverified]` (fallback: client-side `issue_type` filtering on `--json`
  output).
- **`pinned`** exists in the schema but is **not settable from the CLI** at
  1.1.0 — use a label instead.
- **Dependencies**: `bd dep add <blocked> <blocker>`; `bd blocked` distinguishes
  gate-blocks from issue-dependency blocks. `bd epic status` reports
  open-children counts (a usable phase-complete predicate).
- **Label filtering bug**: `--label`, `--label-any`, `--exclude-label` work;
  **`--label-pattern` and `--label-regex` are broken at 1.1.0** — they return
  the full set instead of filtering. A label vocabulary must therefore be a
  bounded exact set, never prefix/glob-matched.
- **Metadata is filter-only**: `--has-metadata-key` / `--metadata-field` filters
  work, but whether metadata _values_ are emitted in `bd show`/`bd list --json`
  or survive a JSONL round-trip is `[unverified]`. Anything that needs read-back
  belongs in `notes`, which round-trips reliably through `bd show` and
  `bd export`.
- **Listing**: `bd list` excludes closed issues by default (`--all` includes
  them); `--deferred` lists deferred items with `defer_until` inline. `bd ready`
  sorts by `priority` by default (`--sort oldest` = `created_at` ascending),
  supports `--parent <epic>` scoping and `--exclude-type`. `created_at` strict
  monotonicity across sequential creates is `[unverified]` — if it is not total,
  `priority` must encode the tiebreak.
- **Defer and gates**: `bd update <id> --defer +<window>` sets `defer_until`; a
  deferred item does **not** self-return to `bd ready` when the date passes — a
  caller must flip it back (e.g. a session-start scan over
  `bd list --deferred --json`). Timer gates exist (`bd gate check` self-release)
  but are only partially characterized `[unverified]` — a wrong-sign trap in the
  release formula and unclear batch semantics were both reported; human/event
  gates block specific issues via `bd gate create --type=human --blocks <id>`.
- **Writes are immediate**: `bd create`/`bd close` mutate Dolt durably with no
  staging layer — there is no "review before commit" seam. Dolt branches are a
  candidate isolation mechanism `[unverified]`. `--claim` and `in_progress`
  support multi-worker fan-out (the flags are measured; the hazard that a
  crashed `in_progress` item drops out of the ready cursor, needing a
  stale-claim reaper, is design reasoning, not observed behavior). `--readonly`
  / `--sandbox` exist for read-only access.
- **Export/import/backup**: `bd export` **drops closed issues by default** —
  `--all` is mandatory for a usable snapshot. `bd export --all` round-trips the
  full work-item plane (register, DAG, cursor state, gates) but **loses Dolt
  commit history and `config.yaml`**. `bd import` takes a positional file;
  recovery is fresh `bd init` + `bd import <file>` + re-applied config. A true
  backup (with history) is `bd backup` or `bd dolt push`.
- **Memory features**: `bd remember` / `bd prime` exist (`bd prime --hook-json`
  is the session-start shape); `bd comment` appends to a threaded per-issue
  event log.
- **Carried from research, entirely `[unverified]`**: custom issue types (a
  `bd types` command reportedly lists them; a reported 2026-03 defect had
  `bd update` accepting a type `bd create` rejected), and _formulas/molecules_ —
  templated subgraphs of issues stamped when "poured", with no known
  post-instantiation re-validation. Probe before relying on either.

## beads-mcp

The official MCP server lives **in the same repo** (`integrations/beads-mcp/`),
is Python (≥3.10) on fastmcp, is published to PyPI as `beads-mcp` (1.2.1 at the
verify date), and **shells out to the `bd` binary** (default: `bd` on PATH,
fallback `~/.local/bin/bd`). Env vars read, per its `config.py` `[upstream]`:

- `BEADS_PATH` — path to the `bd` binary
- `BEADS_DIR` — path to the `.beads` directory (default: auto-discover)
- `BEADS_DB` — **deprecated**; use `BEADS_DIR`
- `BEADS_WORKING_DIR` — working directory for `bd` commands (default: cwd)
- `BEADS_ACTOR`, `BEADS_NO_AUTO_FLUSH`, `BEADS_NO_AUTO_IMPORT`

Earlier research (2026-07) recorded the opposite — that the server read only
`BEADS_WORKING_DIR`/`BEADS_DB` and **not** `BEADS_DIR`. Current source refutes
that; either the surface changed between versions or the earlier claim was
wrong. Re-verify against the pinned version before wiring the env block, and
note the general lesson stands: an MCP server's env surface is distinct from the
CLI's and must be confirmed per tool, never assumed shared.

## Field reports

Agents do not proactively use `bd`: instruction-file guidance fades over long
sessions, and hooks help but are not magic. `[upstream]` This is why the
consuming design treats retrieval as solved prior art but the **write-path
trigger** (firing dedup/context at `bd create` time) as the unsolved part — see
`ecosystem.md`.
