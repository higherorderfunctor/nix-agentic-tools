# bd (beads) — tool reference

> **Last verified:** 2026-08-16 against the repository package pin at stable
> Beads v1.2.2, nixpkgs Beads 1.0.3 and Dolt 2.2.4, plus the upstream and
> `numtide/llm-agents.nix` derivations. Companion documents:
> `dolt-git-remotes.md` (remote/sync mechanics) and `ecosystem.md` (integrations
> and prior art). GitHub issue
> [#986](https://github.com/higherorderfunctor/nix-agentic-tools/issues/986) and
> its children are the consuming plan of record.
>
> **Provenance tags.** `[measured @1.1.0]` — observed by running the real `bd`
> v1.1.0 binary during a hands-on evaluation (2026-07).
> `[measured package @1.2.2]` — asserted by the Nix package's build or install
> checks. `[measured package session @1.2.2/2.2.4]` — observed directly against
> the exact packaged binary outside its install check.
> `[measured contract @1.2.2/2.2.4]` — asserted by the disposable black-box
> `beads-contracts` flake check. `[measured server probe @1.2.2/2.2.4]` —
> asserted by `checks/beads-server-contracts.sh`, a dynamic-port disposable
> probe run outside the Nix build sandbox.
> `[measured recovery probe @1.2.2/2.2.4]` — asserted by
> `checks/beads-recovery-contracts.sh`, the repeated serialized
> write/publish/cold-restore probe. `[measured lifecycle check @1.2.2/2.2.4]` —
> asserted by the isolated `beads-lifecycle` flake check against the generated
> devenv lifecycle. `[measured session @1.2.2/2.2.3]` — retained in #991's
> timestamped investigation record, but not asserted by either durable probe.
> `[measured Dolt @2.2.3]` — observed by running the pinned Dolt binary under a
> clean temporary home. `[upstream]` — read from upstream docs or source at the
> date above. `[unverified]` — carried from research that never executed the
> binary; quarantine until probed. Claims can go stale in either direction;
> re-verify against the pinned version before building on a load-bearing one.
> Claim-local durable-probe tags naming 2.2.3 preserve the first measurement;
> the current contract, server, and recovery probes requalified those surfaces
> against 2.2.4. Session and transaction-spike tags remain 2.2.3-only evidence.

## What beads is

Beads is a distributed graph issue tracker built for coding agents: a `bd` CLI
over a dependency DAG of issues, with `bd ready` / `bd blocked` as the
work-queue primitives. MIT-licensed, no web UI by design. Storage is **Dolt** (a
version-controlled SQL database with cell-level merge and native branching);
beads migrated off JSONL/SQLite, so pre-migration writeups are stale on storage
and sync. Issue IDs are hash-based (`bd-a1b2`) to avoid merge collisions across
concurrent agents and branches. Upstream sync exposes `bd dolt push` and
`bd dolt pull` against a Dolt remote; the qualified module protocol below uses
only serialized no-force publication and cold replacement recovery. Old closed
issues can be compacted ("memory decay") via `bd admin compact --days N` plus
Dolt garbage collection. `[upstream]`

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

## Versions and packaging state (2026-08-16)

- **Upstream**: latest stable release **v1.2.2** (2026-08-15). The immediately
  preceding **v1.2.1** release remains marked prerelease. `[upstream]`
- **nixpkgs**: `beads` **1.0.3** on nixos-unstable (`pkgs/by-name/be/beads/`),
  absent from the 25.11 release. `buildGoModule`, `subPackages = ["cmd/bd"]`,
  `buildInputs = [icu]`, MIT, `mainProgram = "bd"`, and a `postInstall` that
  wraps `dolt` onto `bd`'s PATH. One test is skipped everywhere
  (`TestCheckMetadataVersionTracking`), a second on Darwin
  (`TestCleanupMergeArtifacts_CommandInjectionPrevention`), and the recipe sets
  `__darwinAllowLocalNetworking`. `[upstream]`
- **This repository**: `pkgs.ai.devTools.beads` pins stable **v1.2.2** from a
  source sidecar and thinly overrides the nixpkgs recipe through the
  repository's `ourPkgs` and derived-Go-floor machinery. The sidecar owns the
  source hash, vendor hash, and `go.mod` floor (**1.26.2**); the stable-release
  update script follows GitHub's `releases/latest` redirect and excludes
  prereleases. `[measured package @1.2.2]`
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
- **dolt**: a separate binary, required for the server modes.
  `bd dolt push/pull` may use the CLI or Dolt SQL procedures; an external server
  whose data directory is not visible to Beads uses `CALL DOLT_PUSH` /
  `CALL DOLT_PULL`. nixpkgs carries Dolt 2.2.4 at this repo's 2026-08 pin
  (Apache-2.0). Dolt's `metrics.disabled` default is false.
  `DOLT_DISABLE_EVENT_FLUSH=1` prevents queued events from being sent but still
  permits local event files; complete collection disablement is the stateful
  user-global `metrics.disabled = true` setting. The repository's `bd` wrapper
  sets the no-flush variable for every Dolt child process. A clean-home `init` +
  `status` probe with `DOLT_DISABLE_EVENT_FLUSH=1` created local event payloads,
  confirming that the wrapper control prevents network flushing but is not the
  collection kill switch. `DOLT_ROOT_PATH=<contained-root>` relocates both
  `.dolt/config_global.json` and `.dolt/eventsData`; setting
  `metrics.disabled=true` there before init leaves exactly the contained global
  config, events directory, and event lock, with no `.devts` payload; a distinct
  clean `HOME` remains empty and the effective global value reads back as
  `true`. Dolt creates some inner global-state paths mode 0777, so the module
  must create and enforce the outer directory's restrictive mode rather than
  inheriting Dolt's defaults. `[measured contract @1.2.2/2.2.3]`
- **Compilation**: `bd` is plain Go. The nixpkgs and llm-agents derivations
  build with cgo/ICU (verified at the date above); the upstream flake's own
  derivation was earlier recorded as a pure-Go build (`gms_pure_go` tag, no cgo)
  and was not re-inspected. No parser toolchain and no WASM appear in any
  inspected derivation — any WASM-versus-native-parser packaging concern belongs
  to codegraph (WASM tree-sitter with an optional native kernel), not to beads.
  `[upstream]`

**Repository wrapper contract.** The nixpkgs recipe already wraps `bd` once to
put Dolt on `PATH`. This repository extends that same `wrapProgram` invocation
with `BD_DISABLE_METRICS=1`, `BD_DISABLE_EVENT_FLUSH=1`, and
`DOLT_DISABLE_EVENT_FLUSH=1`; it does not wrap the result again. The install
check rejects a missing or second hidden wrapper, runs `bd --version` and
`bd metrics` under `env -i`, and exercises the Dolt command surface.
`[measured package @1.2.2]`

## Devenv lifecycle module

The opt-in `services.beads` module is the supported repository lifecycle. It
requires `issuePrefix` and the exact credential-free `ledgerUrl`, installs the
pinned CLI behind a serialized guard, and launches the paired pinned Dolt from
the Beads package's `passthru.dolt`. It is devenv-only: there is no
`ai.programs.beads` tree and no Home Manager operational surface. This
repository deliberately leaves it disabled; #994 owns the first real-ledger
exercise after #993 supplies agent-runtime wiring.

`devenv up` starts the shared external Dolt daemon and a publisher process. The
daemon holds a repository-scoped lifetime lease, and clients require that lease
plus loopback readiness before initialization. Every publisher invocation uses
the sole validated raw-Dolt pusher path under the repository lock. The pusher
quiesces the leased Dolt child before opening its data directory, publishes,
then resumes the child before final validation and unlock. It performs
module-owned initialization or exact existing-state verification, drains once at
startup, then publishes on the bounded interval. Shell activation runs only
`beads:prepare`, which creates and verifies contained runtime configuration
under the same lock and never publishes. Operators and agents do not run
`bd init`; `beads-bootstrap` and the `beads:bootstrap` task are the explicit
module-owned entry points.

The installed `bd` acquires the repository-wide lock even for reads, rejects
unqualified lifecycle/configuration/recovery commands, verifies clean valid
incoming state, executes the pinned client with auto-commit batching, crosses
the commit-if-needed barrier, and verifies the committed checkpoint before
unlocking. `beads-checkpoint`, `beads-status`, and `beads-diagnostics` expose
the corresponding validation and observation paths. Runtime state is selected
from the shared Git common directory below `XDG_STATE_HOME`, so linked worktrees
share one ledger without writing into either checkout. The isolated fixture
covers equal and different source/ledger URLs, linked-worktree lock contention,
foreign-port refusal, safe re-entry, cold existing-ledger bootstrap, startup and
interval publication contents, remote divergence, dirty and committed invalid
refusal, public entry points, and unchanged source/global configuration.
`[measured lifecycle check @1.2.2/2.2.4]`

**Unattended bump risk.** The update target proves that a new stable release
builds and preserves the package contract, but it does not open or migrate an
existing ledger. A stable release can still introduce a schema migration, so an
automatic version bump is not evidence that a shared ledger can be upgraded or
rolled back unattended. Issue
[#995](https://github.com/higherorderfunctor/nix-agentic-tools/issues/995) owns
that lifecycle hardening.

**Version-skew boundary.** The packaged 1.0.3 client refuses a fresh 1.2.2 DB
with `table has unknown fields`. The 1.2.2 client can open and write a 1.0.3 DB,
after which 1.0.3 can still read it. `bd migrate --inspect --json` reports the
version-label mismatch, while `bd migrate schema --json` reports schema v53
already current; this version pair therefore does not exercise a destructive
migration or post-migration bootstrap. Supporting one remains gated by #995.
Until then, one pinned `bd` package is authoritative and rollback requires a
pre-upgrade `bd backup` or recoverable remote ref plus the previous binary.
`[measured contract @1.2.2/2.2.3]`

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

`bd config show --json` returns an array of `{key, value, source}` records,
which makes an intended-versus-effective assertion task possible. In the
contained fixture, `no-git-ops` reports `config.yaml` provenance and embedded
`dolt.auto-commit` resolves to `on`. `bd config get` reads individual keys.
`[measured contract @1.2.2/2.2.3]` The YAML config is a working-tree file and is
**not** included in `bd export`; posture config must be re-applied after any
rebuild from JSONL `[measured @1.1.0]`.

**Native bootstrap is the recovery primitive, not the general activation
primitive.** Fresh `bd bootstrap` restores the published rows and exact Dolt
history through an external server when `BEADS_DIR` is a literal `.beads`
directory, `sync.remote` is declared, and the target database is absent. With
`sync.remote` still set, a second invocation selects clone again and fails
because the database exists. Activation must therefore bootstrap only an absent
database and verify an existing one without rerunning bootstrap. Qualified
recovery compares the restored HEAD, table set, issues, dependencies, events,
actor attribution, and history exactly; requires clean state with zero direct
orphans and constraint violations; then writes, republishes, and repeats the
cold restore. `bd vc log` is not a validation command in 1.2.2: it prints help
and exits zero because no `log` subcommand exists. Verify restored history with
read-only `dolt log` from the resolved database directory.
`[measured recovery probe @1.2.2/2.2.3]`

**Secrets.** Dolt-server credentials live in an INI file at
`~/.config/beads/credentials` (directory `beads`, **not** `bd`), sections keyed
`[host:port]`. The pinned binary warns on a mode-0644 fake credentials file and
stops warning after mode 0600; the server probe uses no real secret. Resolution
order is documented upstream as `BEADS_DOLT_PASSWORD` → credentials file →
empty, but value precedence is not independently qualified because the
passwordless disposable root account accepts arbitrary password values. Keys
matching `api_key|secret|token|password` are **refused** on a git-tracked
`config.yaml` unless `--force-git-tracked`.
`[measured server probe @1.2.2/2.2.3; upstream for precedence]`

## Init residue and the pure-data-engine posture

`bd init` self-wires and is not safe to delegate to an operator or agent. In a
source checkout,
`--non-interactive --init-if-missing --skip-agents --skip-hooks` still creates
Beads files, sets local `beads.role=maintainer`, and creates a Git commit.
Adding `--stealth` leaves HEAD unchanged but still sets `beads.role`, writes
`.git/info/exclude`, and replaces the Beads config with `no-git-ops: true`.
Pre-seeding an external config with `no-git-ops: true` stops source commits but
does not stop the `beads.role` mutation when cwd is a Git checkout.
`[measured contract @1.2.2/2.2.3]`

The ordinary skip-flags fixture's complete top-level residue is `.beads/` with
the `embeddeddolt/` directory and `.gitignore`, `.local_version`, `README.md`,
`config.yaml`, `interactions.jsonl`, and `metadata.json`, plus root
`.gitignore`. Its init commit tracks all except `.local_version`; its exact
subject is `bd init: initialize beads issue tracking`. The only local Git-config
delta is `beads.role=maintainer`, and the pre-existing hook set is unchanged.
Standalone `--stealth` creates the same Beads top-level files, keeps the
worktree clean and HEAD fixed, leaves hooks/AGENTS.md absent, adds only
`beads.role`, writes exactly `no-git-ops: true`, and makes the Beads-labeled
stealth block the only `.git/info/exclude` change.
`[measured contract @1.2.2/2.2.3]`

The minimal contained initialization is module-owned: run from a neutral,
non-Git cwd with an explicit out-of-tree `BEADS_DIR`; create its mode-0700
parent and mode-0600 `config.yaml` containing `no-git-ops: true` first; then run
`bd init --non-interactive --init-if-missing --skip-agents --skip-hooks --prefix <prefix>`
and, for a remote-backed ledger, always add `--remote <exact URL>`. The neutral
cwd remains empty. A repeat exits zero with
`Skipping init: workspace already initialized.` The module must chmod the
pre-created config: `bd init` tightens generated metadata but preserves an
overly broad existing config mode. `[measured contract @1.2.2/2.2.3]`

The remaining disable surface is:

- `--quiet --skip-agents --skip-hooks` — suppress the individual writes;
  `--stealth` = all three plus `no-git-ops: true`. `[upstream]`
- `bd onboard` **prints** the agent-instructions snippet instead of writing it,
  which is what makes declarative placement possible. `[upstream]`
- `bd setup` at the pinned **v1.2.2** stable line has no Kiro target. The v1.2.1
  prerelease briefly included Kiro, but v1.2.2 is a recovery release based on
  the tested 1.1 line and omits that 1.2.x-only recipe. The exact packaged
  binary's `bd setup --list` output is the contract; version-scope any claim
  about setup targets. `[measured package session @1.2.2/2.2.4]`
- Git hooks, when wanted at all, are thin shims calling `bd hooks run <name>`; a
  declarative hook manager can invoke that directly and skip bd's installer.
  `[upstream]`
- Telemetry kill switches: `BD_DISABLE_METRICS=1`, `BD_DISABLE_EVENT_FLUSH=1`.
  The repository package bakes both into its sole `bd` wrapper, below any module
  layer. `[measured package @1.2.2]`

Storage layout under a project-local workspace: `.beads/config.yaml` (track),
`.beads/metadata.json` (track), `.beads/.gitignore` (bd-written),
`.beads/embeddeddolt/` and `.beads/dolt/` (never track). `[upstream]`

## Storage modes

- **Embedded** (default): linked worktrees can share an external `BEADS_DIR`.
  Sixteen concurrent writes all persisted in one disposable run, but serialized
  at roughly 18 seconds. This is a compatibility fallback, not the intended
  multi-writer mode. `[measured session @1.2.2/2.2.3]`
- **Server**: an external `dolt sql-server`; default port 3307. An explicit
  `bd init --server --external --server-host <loopback> --server-port <port> --database <name>`
  works with an out-of-tree workspace. Before mutation, the durable probe
  authenticates a read-only query with the private secret from that server's
  `sql-server.info`; an open port and live PID alone do not prove endpoint
  ownership. `bd dolt show --json` then reports `connection_ok: true` plus the
  exact host, port, and database. `bd dolt status` reports `running: false` and
  `bd dolt stop` refuses because bd does not own the external process.
  `[measured server probe @1.2.2/2.2.3]`
- **Native server lifecycle**: `bd init --server` without `--external`
  auto-starts a background server and writes project-local lock, log, PID, and
  port files. `bd dolt status/start/stop` observe and control that process. A
  forced crash is reported as stopped and is not restarted automatically;
  explicit `bd dolt start` recovers it. The pinned native lifecycle therefore
  supplies no restart/backoff policy. `[measured server probe @1.2.2/2.2.3]`
- **Shared-server**: one Dolt server at `~/.beads/shared-server/`, default port
  **3308** (3307 is reserved for the plain server, 3306 for real MySQL), with a
  per-project database selected by **prefix**. Enable via
  `dolt.shared-server: true`, `BEADS_DOLT_SHARED_SERVER=1`, or
  `bd init --prefix X --shared-server`. Two projects sharing a prefix share a
  DB; an identity check **refuses the connection** (fails safe, but fails) — the
  exact error shape is unqualified. The packaged `--shared-server` path did not
  create a usable explicitly external workspace in the disposable probe, so it
  is excluded from the MVP rather than repaired by wrapper glue.
  `[measured session @1.2.2/2.2.3]`

**The currently qualified serialized checkpoint policy is load-bearing.** In
SQL-server mode, `--dolt-auto-commit off` does not suppress the store's own Dolt
commit. Ordinary `CreateIssue` commits its issue/event SQL transaction, returns,
and then stages and commits through a separately acquired pooled connection; it
does not use the connection-pinned `RunInTransaction` path. A successful command
and a complete live working-set read therefore do not prove that the committed,
publishable HEAD is complete. The rejected concurrent-writer probe demonstrated
the distinction: every CLI write succeeded and the live rows were visible, but
cold recovery of the exact published HEAD exposed seven orphan events and
foreign-key violations. `[measured session @1.2.2/2.2.3]`

The qualified path holds one repository lock across each complete mutation and
the sole raw-Dolt pusher. Immediately after acquiring it, a mutation rejects
pre-existing dirty or invalid state rather than absorbing residue from an
interrupted predecessor. Before unlocking, it must leave an advanced final HEAD,
a clean committed working set, zero constraint violations, zero direct
event/dependency orphans, and unchanged source Git state. A following
`bd dolt commit` is commit-if-needed normalization, not the source of
server-mode safety. Three repeated serialized write/publish/absent-state restore
cycles preserved the exact application state and history; each included a
post-restore write, forward republish, and third cold restore. A terminal
negative control proved that dirty incoming state refuses the next mutation
without executing it or changing HEAD/history. Pull, merge, rebase, conflict
resolution, repair, and force-push are outside the qualified protocol.
`[measured recovery probe @1.2.2/2.2.3; requalified recovery probe @1.2.2/2.2.4; upstream source @Beads 1.2.2]`

A bounded transaction-native experiment does not replace that policy. Global
`behavior.dolt_transaction_commit=true` broke fresh migration 0040 and changed
cold-bootstrap HEAD/history. Enabling it only after DTC-off init/bootstrap
preserved the tested ordinary concurrent creates, labels, comments, clean state,
and exact cold restore, but did not cover upgrades, true same-row updates,
writer/publisher overlap, command messages/authors, or crashes during commits
and mode transitions. Session-scoped DTC/message settings and direct
in-transaction `DOLT_COMMIT` are credible ingredients for a future Beads fix;
the tested rollback failed before `DOLT_COMMIT`, and pinned active transaction
paths remain heterogeneous. A separate transaction-boundary follow-up may
reconsider only writer serialization after those gaps close. The pusher remains
exclusive without an independently proven compare-and-publish protocol.
`[measured #991 transaction spike @1.2.2/2.2.3; upstream source @Beads 1.2.2]`

**Split-brain**: external init persists its selected port as `dolt_server_port`
in `.beads/metadata.json`; a stale value is honored and fails loudly with
connection refused. `BEADS_DOLT_SERVER_PORT` overrides the stale metadata and
restores the connection. The process environment and `bd dolt show --json` must
therefore be authoritative. Killing the server makes writes fail loudly; the
client output contains the connection failure context. A server-mode row
survived a kill and restart in the disposable probe, but the minimum supported
recovery remains backup/remote-ref based rather than relying on process-local
working-set behavior. `[measured server probe @1.2.2/2.2.3]`

**Process residue**: embedded commands left no resident `bd` or Dolt process in
the measured session. External-server mode leaves only the supervisor-owned
`dolt sql-server`; bd's status/stop commands do not adopt it, and the durable
probe's bounded cleanup trap terminates it. Native-server mode leaves the
documented project-local process files and one bd-owned server until explicit
stop. No write performed an automatic `bd dolt push`.
`[measured session @1.2.2/2.2.3; measured server probe @1.2.2/2.2.3; measured contract @1.2.2/2.2.3 for publication]`

## Workspace resolution and isolation

With no override, a source checkout and its linked worktree both resolve the
main worktree's `.beads`. `bd where --json` reports `path`, `database_path`,
`prefix`, and `schema_version`. Outside Git with no state it exits nonzero with
JSON `error: no_beads_directory`. `[measured contract @1.2.2/2.2.3]`

`BEADS_DIR` is not a fail-closed escape hatch. When it names a missing or empty
directory, bd silently ignores it and falls back to the source checkout's
`.beads`. When the variable is unset, the same source fallback applies.
Therefore every managed invocation must set `BEADS_DIR` **and** assert that
`bd where --json | .path` exactly equals the declared state path before a write.
The state directory and config must be materialized before that assertion. A
neutral non-Git cwd is additionally required for initialization because even a
valid external workspace does not prevent bd from setting `beads.role` in the
cwd repository. `[measured contract @1.2.2/2.2.3]`

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
