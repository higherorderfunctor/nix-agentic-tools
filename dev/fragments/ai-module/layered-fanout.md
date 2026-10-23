## ai.* layered fanout

> **Last verified:** 2026-10-22 — Instance-owned named CPA routing replaces
> runtime-published keys and rules; the proxy selection is an ordinary
> normalized scalar surface.

Full earlier detail:
`git show 16168044:dev/fragments/ai-module/layered-fanout.md`. The files
contract and backend rules live in `packages/ai-module/docs/contract.md`; fanout
stages below are separate from its files layers.

### Five fanout stages

| Stage | Shape                                             | Owner                                    |
| ----- | ------------------------------------------------- | ---------------------------------------- |
| L1    | Optional `ai.<pool>Dir`                           | `sharedOptions.nix`, pure Dir helper     |
| L2    | Root `ai.<pool>` entries                          | `sharedSurfaceOptions`                   |
| L2b   | Optional per-runtime Dir input                    | `mkBackendTransform.nix`                 |
| L3    | Per-runtime entries, then `normalized.<pool>`     | Transform root-to-runtime fold           |
| L4    | `_generatedFiles` → `ai.<runtime>.files`          | Runtime factory and `generatedFiles.nix` |
| L5    | `ai.files`, `ai.activation`, native backend sinks | ai-module alone                          |

L1/L2/L2b only reshape data. They never write runtime artifacts or backend
sinks. A Dir option contributes individual files rather than taking a
destination directory wholesale. Dir helpers live in `lib.ai.*`, work without
modules, and retain each entry's key through suffix stripping and final
rendering.

### Placement and record validation

A runtime record's `optionNamespaces` maps only `launcher` and `pools` to
relative paths; omitted groups stay at its root. Kiro moves launcher options
beneath `cli`; Copilot moves pools beneath `github`.
`lib/ai/app/optionNamespaces.nix` controls declarations, defaults, callback
reads, diagnostics and contributors together. Native agents and file/ledger
options remain at the runtime root. Callbacks receive shared `cfg` and one
normalized view.

`checkRecord.nix` validates at construction and transformation. Every placement
value is a list of nonempty strings. `poolOptions` can override `agentsDir` and
`environmentVariables`, only with the corresponding supported pool; it cannot
override `agents`. `agentsDescriptionSuffix` supplies only a runtime-specific
suffix. `agentNativeType` and `agentTransformer` must appear together and
require the agents pool, as do agent suffixes. `agentsDirSuffixes` must be a
nonempty string list. Explicit null counts as presence for the native pair.

CPA selects through the proxy pool without runtime record defaults:
`lib/ai/proxy/default.nix` resolves `instance` + `clientKey` or external `url` +
redact `key`. The Instance owns named upstream credentials and routes; no
runtime publishes client keys or allowlist rules. See
`dev/fragments/ai-proxy/ai-proxy.md`.

Keyed runtime entries atomically replace same-key root entries. Nullable pools
use null as withdrawal; rules use `enable = false`. Dir expansions use
`mkDefault` within their layer. Unsupported root requests warn and lower to the
pool's neutral value; unsupported per-runtime options do not exist. Runtime
`surfaceSupport` is the sole capability declaration.

Normalized keyed pools are ordinary options: neutral `{}` option defaults plus
per-key fold defaults preserve unrelated inherited entries. Whole-pool `mkForce`
replaces the pool. Scalar surfaces use their complete fold as the default. Every
renderer reads normalized values; older callback argument names alias them. MCP
entries are already lowered client records. Hooks carry portable root input and
append root matcher groups before runtime groups per event.

Context concatenates root-first. Text/source records carry only their winning
arm: carrying both fails equal-priority validation and can force discarded
sources. Structural presence gates generated defaults lazily; normalized
overrides supply their own presence.

### Files and state

Every owner declares files at layer 1; ai-module forwards and lowers them.
Enabled owners claim paths even for disabled file entries; disabled owners
forward nothing. Shared repository context forwards unclaimed so the shared
composer remains its sole owner. Same-priority agreeing content merges and
divergent content conflicts.

Staged Markdown and raw content receive whole-content defaults, keeping
discarded sources lazy. Structured settings contribute defaults per leaf,
preserving generated siblings when a consumer adds a leaf. Consumers arbitrate
content using ordinary priorities.

**Settled — do not relitigate.** Choose delivery by the CLI's write primitive:

- Store symlink: Codex `config.toml`, whose writer follows the link and cannot
  replace the immutable target.
- Read-only copy: Codex daemon settings, Kiro settings and hooks, Kimchi
  MCP/permissions/trust; their writers rename over files. The engine backs up
  edits and restores declarations at activation.
- Writable overlay: Claude `.claude.json`, Kimchi user `config.json` and harness
  settings, because they also hold login/model state. Kimchi's latter two were
  read-only copies on 2026-09-29–30 and broke `/login`; never restore that
  method.

Claude stages every surface itself. Home Manager alone writes `.claude.json`,
consumer plugins and the MCP personal plugin; devenv writes project `.mcp.json`.
Both settings and MCP configuration use read-only links. `claude-config-mode`
activation follows `materialized` and strips group/other access from regular
files while enabled.

Claude's project rule loader refuses external symlinks
(`includeExternal: false`), so rules use
`method = {devenv = "ro"; hm = "symlink";}`. Codex's execpolicy scan requires
`DirEntry::file_type().is_file()`, so rules are raw read-only copies on both
backends; native `default.rules` remains alongside them. Kiro's hook scan also
requires real files.

Retirement survives disable. Every runtime declares old writers' `legacyLedgers`
through ungated `migrationConfig`; the engine imports and retires absent paths
before native link checks. Codex declares execpolicy ledgers on both backends
and daemon settings on Home Manager. Commands use owner activation, including
the Codex skill-link migrator before `linkCheck` and its Home Manager daemon
selector with `runWhenDisabled`.

### Shared repository context

`sharedAgentsMd` returns `key`, rules and optional `index`, `hasOnDemandIndex`,
`maxBytes`; unknown fields or missing key fail. A limit is published even
without content.

`sharedAgentsMd.nix` arbitrates the public entry, stages its winner and forwards
through owner `internal`, as a read-only copy by default. Same-key identical
contributions deduplicate. Scoped referenced rules become index entries; other
scoped rules inline with a scope note. The renderer writes the index before
context, preserving routing within Codex's default 32 KiB budget. Codex's
launcher independently checks actual truncation on either backend in any
repository.

Rule inclusion resolves before L4: each runtime chooses its first supported
portable trigger. `fileMatch` requires matcher metadata or explicit flat-file
scope prose. Codex/Kimchi support `auto` and `manual` through nonempty
references. Formatter layout is one blank line between units and after rule
comments, one glob/link per index line.

### Delivery facts and new concerns

`config/ai-delivery.nix` derives pure facts from shared declarations and runtime
records. Static gaps become children; dynamic predicates stay record
diagnostics. Hand rows cover only policy-only permissions. Home Manager-only
native options belong in `hm.options` (Claude unpin flags), rather than adding
unavailable devenv options. Native-only writers may coexist with an unsupported
normalized pool (Kiro hooks/settings).

A new concern adds root declaration, per-runtime normalization, capability
declaration and L4 staged output together, with provenance, withdrawal and
unsupported-runtime controls. Backend delivery stays in ai-module; managed MCP
proxies use `ai.internal.services`, and only their lowered client entries enter
fanout.
