## ai.\* Layered Fanout Pattern

> **Last verified:** 2026-10-08 — Kiro launcher controls and normalized launcher
> pools use `ai.kiro.cli`; shared pools and delivery stay at `ai.kiro`; Codex
> checks document truncation at launch rather than through shared shell entry.
>
> Full lineage: `git show ce31eaaa:dev/fragments/ai-module/layered-fanout.md`.

**Settled — do not relitigate.** User-local settings are asserted at switch.
Choose a store symlink when an in-app write fails cleanly (Codex `config.toml`),
a read-only copy when the CLI renames over its file (Copilot, Kiro, Kimchi's
`mcp.json`/`permissions.json`/`trust.json` and Codex daemon settings), and a
switch-time overlay only for a mixed state file (Claude `~/.claude.json`,
Copilot `~/.copilot/config.json`, Kimchi's user `config.json` and
`harness/settings.json`, which carry `/login` and `/model` state). The overlay
repairs Nix-owned leaves while preserving harness state. Kimchi's two were
read-only copies from 2026-09-29 to 2026-09-30, which locked `/login` out; do
not move them back.

| Mechanism                     | Portability and effect                                                                              | Decision               |
| ----------------------------- | --------------------------------------------------------------------------------------------------- | ---------------------- |
| Switch-time overlay           | Linux and macOS; repairs on switch                                                                  | Chosen for mixed state |
| File watcher                  | systemd path or launchd WatchPaths; races on macOS                                                  | Declined               |
| FUSE overlay                  | setuid helper or macFUSE/FUSE-T, unavailable in nixpkgs; whole-file renames defeat per-key blocking | Rejected               |
| Root managed-settings layers  | Require system ownership outside user scope                                                         | Rejected               |
| Environment or flag shadowing | Wrapper-launched sessions only, where the CLI exposes an input                                      | Used where available   |

### Canonical layered shape

```
┌────────────────────────────────────────────────────────────┐
│ L1: Top-level Dir option (optional)                        │
│   ai.<X>Dir = path | { path, filter? }                     │
└────────────────────────────────────────────────────────────┘
                             │
                             ▼  fanout via lib.ai.<X>FromDir
┌────────────────────────────────────────────────────────────┐
│ L2: Top-level singles                                      │
│   ai.<X> = attrsOf (<itemModule>)                          │
│   - cross-ecosystem pool                                   │
│   - nullable pools wrap itemModule in nullOr               │
│   - rules use itemModule.enable                            │
└────────────────────────────────────────────────────────────┘
                             │
                             ▼  fanout to each enabled CLI
┌────────────────────────────────────────────────────────────┐
│ L2b: Per-CLI Dir option (optional)                         │
│   ai.<cli>.<X>Dir = path | { path, filter? }               │
└────────────────────────────────────────────────────────────┘
                             │
                             ▼  fanout via lib.ai.<X>FromDir
┌────────────────────────────────────────────────────────────┐
│ L3: Per-CLI singles                                        │
│   ai.<cli>.<X> = attrsOf (<itemModule>)                    │
│   - exists only when the app record supports pool X        │
│   - same-key value atomically replaces L2                  │
│   - null or itemModule.enable suppresses by pool contract   │
└────────────────────────────────────────────────────────────┘
                             │
                             ▼  root-to-runtime fold
                  ai.<cli>.normalized.<pool>
                  ordinary option; per-key fold defaults
                             │
                             ▼  routing + native rendering
┌────────────────────────────────────────────────────────────┐
│ L4: Final runtime output map                               │
│   ai.<cli>.files = attrsOf (nullOr { content; ... })       │
│   - text/source default; structured leaves compose         │
│   - sibling fields compose; null suppresses entries       │
└────────────────────────────────────────────────────────────┘
                             │
                             ▼  generic backend lowering
┌────────────────────────────────────────────────────────────┐
│ L5: Native file sink                                       │
│   - HM: home.file.*                                        │
│   - Devenv: files.*                                        │
└────────────────────────────────────────────────────────────┘
```

The runtime record has one data-only placement field, `launcherOptionsPath`,
default `[]`. Kiro sets `["cli"]`: only package, environment, shell and the
corresponding normalized inputs move there. Declarations, per-key fold defaults
and callback reads share that path. Callbacks still receive the shared `cfg` and
one complete `normalized` view. Native agents and every file/ledger remain at
the runtime root. The field must be a list of nonempty strings; constructor and
transform both validate it.

### Rules

- **Artifact routing/rendering lives at L4; physical emission lives at L5.**
  L1/L2/L2b are pure fanout — they never touch `ai.<runtime>.files`,
  `home.file.*`, or devenv `files.*`. The one sidecar exception is managed MCP
  proxy ownership: `sharedOptions.nix` aggregates proxy declaration scopes and
  emits unique active systemd units, while only lowered client entries traverse
  this five-stage pipeline.
- **One owner per physical path.** Enabled runtime file maps supply claims on
  both backends. Only shared repository context targets arbitrate multiple
  runtime claims; contributors are discovered from their context target and
  delivery options, without a runtime-name list. Public overrides and disabled
  entries enter the aggregate before lowering, and claimants must agree with its
  symlink method. All three readers use `deliveryMethod.resolve`, so an explicit
  method beats `methodFor` consistently after option merging. Kimchi's devenv
  project context is one of those claimants; its user context stays under its
  harness directory.
- **AGENTS.md keeps a whole-entry default.** Codex and the shared repository
  writer decide whether a file exists by reading composed content. Deferring
  that read until priority arbitration keeps replaced store sources lazy.
- **Structured documents contribute ordinary leaves.** Codex settings and
  Copilot MCP/LSP use `content.value` at ordinary priority. Adding one leaf
  keeps generated siblings; defaulting the whole content would silently drop
  them. Text and source content retain their whole-content defaults.
- **Claude delivers its own files.** Agents, commands, output styles, hook
  scripts, skills, plugins, `.claude/settings.json` and the MCP/LSP files are
  ordinary `ai.claude.files` entries, like every other runtime's. All of them
  reach both backends except consumer plugins and the MCP/LSP personal plugin
  (its manifest, `.mcp.json` and `.lsp.json`), which are Home Manager only
  because a plugin is user-scope; devenv writes MCP servers to the project
  `.mcp.json` instead. Nothing is handed to an upstream Home Manager or devenv
  Claude module. Settings and MCP servers are configuration, so
  `.claude/settings.json` and the devenv `.mcp.json` are Nix-owned read-only
  links rather than reconciled documents, and an in-app change such as `/tui`
  does not persist. Every settings contribution goes through
  `ai.claude.native.settings`, so one entry carries the whole document. Claude's
  user-global `.claude.json` is the exception: it holds OAuth tokens and runtime
  state, so it claims the existing JSON ledger under `claudeUnpinLaunchEffort`;
  its writer survives empty declarations and remains Home Manager only. That
  writer keeps whatever mode it finds, whether or not it rewrites the file, so
  an ungated `claudeConfigMode` command writer is the only thing that narrows
  the token-bearing file to owner-only, on every activation.
- **The CLI's write primitive picks the method.** Codex's `config.toml` is a
  store symlink on both backends: every Codex config writer writes a temporary
  beside the link's target, so an in-app save fails and the link survives
  (`chatgpt-codex-readonly-config`). Its daemon `settings.json` is the opposite
  case: Codex renames a temporary over it, which would swap a link for a real
  file and fail the next switch's link check, so it is a read-only copy of
  `materialize-codex-daemon-settings`, claimed file by file in the
  `app-server-daemon` directory. Copilot, Kiro and Kimchi rename too, so their
  settings are copies as well.
- **Writers belong beside the file map.** Codex's skill-link migrator owns no
  ledger and uses `activation.<name>.command`: HM needs `after = []` and
  `before = ["linkCheck"]`, while devenv uses the default file/shell edges.
  Commands omit a final newline because the router supplies it, along with
  strict mode and a scoped subshell. Directory skill sources keep
  `recursive = false` because Codex discovers directory symlinks.
- **devenv guards native link updates.** For a runtime with symlink entries, the
  router emits `ai:<runtime>:guard-symlink-updates` from the lowered file map,
  including recursive leaves whose final `copyMode` is `symlink`, using
  `config.files.<path>.file` as the desired target (including executable
  wrappers). It runs after file cleanup and all owned and command writers of its
  runtime ordered before file creation, then before `devenv:files`. It removes
  stale store-backed links, and fails loudly on a real file or directory at a
  delivered path, where devenv itself would only warn and skip. For a non-store
  link, devenv ran `ln -sf` without `-n`: a link to a file, or a dangling link,
  was replaced, but a link to a writable directory was followed, leaving the old
  link and adding a stray link inside that directory. The guard now refuses
  both. A cross-owner handoff from an owned copy to a symlink can fail the guard
  for one shell entry until the other owner's retraction has run. It reports
  every offender before failing. A failed guard makes `devenv:files` and
  `devenv:enterShell` `DependencyFailed`: shell entry continues with a warning,
  but no `files.*` entry from any runtime or the user is created or updated, and
  `devenv test` fails.
- **Shared documents reconcile harness state.** Claude's `.claude.json` and
  Copilot's HM `config.json` are writable state files with Nix-owned leaves. The
  adapter runs their JSON bundles on activation and retains unowned state.
  `helpers.mkReconciledDocument` emits each writer and file entry together; its
  ledger name remains a literal upgrade contract. Kimchi's `config.json` is
  fully Nix-owned and lands in the same directory copy writer as its other
  settings. A replaced copy is restored at switch.
- **A document ledger reserves its path against symlink delivery.** Both
  `method` and `methodFor` overrides are rejected on HM/devenv when the resolved
  symlink destination still has a declared JSON ledger, even without a claimant.
  Empty retirement preserves the regular document and native siblings; it cannot
  safely hand that path to a link writer. Ordinary empty retirement remains
  supported.
- **Owned entries must agree with their ledgers.** `copy-ro` requires a
  directory ledger. A document claimant's path and format must exactly match its
  JSON ledger: the ledger controls the actual destination and codec, so a
  mismatch would redirect output or silently change its ownership semantics.
- **Kiro's settings files are read-only copies from one writer.** `kiroMcpJson`
  owns `cli.json` and `mcp.json` through one directory ledger,
  `materialize/kiro-settings.manifest`. Kiro's own writers rename a temporary
  over either file, which replaces a symlink and a 0444 copy alike. A copy is
  still the right method: the next activation or shell entry backs the in-app
  file up and restores the declaration, while a symlink would block Home
  Manager's link check or be skipped by devenv. Home Manager always claims both
  user-global files (`{}` and an empty server map); devenv claims a project file
  only when something is declared. `mcp.json` is 0400 with a URL secret,
  otherwise 0444. Only this writer waits for secrets. The devenv renderer keeps
  its project-root anchor for relative secret readers. Hooks state
  `facts.symlinkReadable = false` because the v3 scan keeps only `isFile()`
  entries, and their writer survives N→0. Permissions remain HM-only because
  Kiro never reads them from project `.kiro/`.
- **Claude project rules are read-only copies on devenv.** Claude's scoped-rule
  (`paths:`) loader passes `includeExternal: false` at Project scope, with no
  setting to change it (claude-code 2.1.280), so a `.claude/rules` symlink into
  the store is never read. User scope passes true. The rules entry therefore
  states `facts.symlinkReadable = {devenv = false; hm = true;}`: devenv resolves
  `copy-ro` through the `ai:claude:materialize-rules` directory ledger, while
  Home Manager keeps its link. The writer is declared on devenv only, from
  `migrationConfig` with `runWhenDisabled = true`, so both N→0 and disabling
  Claude retract the copies.
- **Codex execpolicy rules are read-only copies on both backends.** Codex keeps
  a `rules/*.rules` entry only when `DirEntry::file_type().is_file()`, which
  does not follow symlinks, so a linked rule is skipped silently (codex
  0.156.0). Each rule states `facts.symlinkReadable = false` and is claimed file
  by file through the `materialize/codex-execpolicy.manifest` directory ledger:
  Codex writes its own `rules/default.rules` beside them, which the ledger never
  records and so never touches. The writer is declared from `migrationConfig`
  with `runWhenDisabled = true`, so both N→0 and disabling Codex retract the
  copies; an `allow` policy must not outlive its declaration.
- **Retirement can survive disable explicitly.** Kiro's `migrationConfig`
  declares its unclaimed steering ledger with `runWhenDisabled = true`, and the
  Claude rules and Codex execpolicy writers declare theirs the same way. The
  adapter strips every file claim and ordinary writer while disabled; the
  opted-in writer keeps both HM phases or the existing devenv task. A directory
  ledger's unit basenames must be unique; the router rejects collisions before a
  claimant can disappear into the attribute map.
- **Replacement and negation at every supported L2↔L3 boundary.** Per-runtime
  entries replace same-key root entries wholesale. Nullable pools use null to
  suppress an inherited entry after the shallow merge; rules use
  `enable = false` on the replacement entry. Unsupported root fanout degrades
  before this boundary and has no L3 option. L1→L2 and L2b→L3 use `mkDefault` so
  explicit entries within the same layer still win before cross-level
  composition.
- **One package owner per key and scope.** Definition-provenance checks reject
  two packages claiming one root key or one per-runtime key. A root key and its
  runtime replacement are different scopes and do not collide.
- **List-valued lifecycle hooks append.** `ai.hooks.<Event>` matcher groups run
  before `ai.<cli>.hooks.<Event>` groups. This is intentional composition, not
  an attrset-entry collision; only the exact portable Claude/Codex event
  vocabulary is accepted at L2.
- **Context content concatenates.** `ai.context` and `ai.<cli>.context` are
  typed `text`/`source` records, not pool entries. The strictly higher-priority
  definition supplies the effective content whichever field it targets; one
  priority setting both fields fails. Their content composes root-first into the
  runtime's `context.filename`; `enable = false` omits either record. A
  structural `hasMergedContext` bit gates the generated default without reading
  composed sources; rendered bytes remain lazy until that default survives B7.
  Repository-local Codex, Kimchi, and Kiro targets contribute to the shared L4
  owner instead of creating competing runtime writers.
- **Rule triggers resolve before L4.** Each runtime selects the first supported
  entry from the portable `inclusion` list through `aiCommon.resolveInclusion`.
  `fileMatch` consumes `matcher` and becomes native routing metadata where one
  exists or explicit prose for flat AGENTS.md consumers. Codex and Kimchi can
  route `auto` and `manual` only through a non-empty `references` index. In the
  shared devenv AGENTS.md, Codex and Kimchi contribute every resolved inline or
  indexed rule; Kiro contributes only rules resolved to `always`. The keyed
  writer deduplicates byte-identical same-key contributions.
- **Merged pools are ordinary options.** `ai.<runtime>.normalized.<pool>` exists
  for each supported pool and is public, writable with `mkForce`. Keyed pools
  have neutral `{}` option defaults and receive the root-to-runtime fold as
  per-key defaults: ordinary additions retain unrelated inherited keys, while
  whole-pool `mkForce` replaces all entries. Other pools default to the complete
  fold. Every transformer argument reads this option; the older argument names
  are aliases of it. MCP entries are already lowered client records. Hooks carry
  the portable root input; native event lists still append inside the runtime.
  Default context presence uses the structural input inventory until final-file
  arbitration keeps its content; an explicit normalized context override
  determines its own presence. A text-source record (context, a rule, agent
  instructions) crosses into its pool with only its WINNING arm, `text` or
  `source`, chosen from the original record's `_sourceWins`. Carrying both lands
  them at one priority, which the record rejects, and computing that priority
  reads the source — a build during evaluation for a derivation.
- **Normalized settings are a uniform scalar-field surface.** Every runtime
  whose `supportedPools` lists `settings` declares the same closed `settings`
  submodule; Kiro does not, because it persists effort only per model. Each
  field resolves root versus per-runtime with `resolveOverride`; native lowering
  remains per-runtime and may support only a subset of fields. Runtime-shaped
  passthrough is separate under `native.settings` and is not a normalized pool.
- **Dir helpers live in `lib.ai.*`**, not in the module layer. They're pure
  (`path → attrset`) and usable outside HM/devenv.
- **Per-file emission only.** A Dir option never takes a destination dir over
  wholesale — other derivations (or consumer's own direct `home.file.*` calls)
  can always contribute alongside.
- **Key identity is preserved.** If a file is named `foo.md` in the source dir,
  the L2 key is `foo` (the helper strips known suffixes before emitting the key,
  and the per-CLI L4 emission re-appends). This is why the `.md.md` doubled-
  extension bug from 2026-04-21 is structurally impossible now.

### Delivery gate controls

`checks/ai-delivery/fixtures.nix` declares typed activation writers and lowers
through the production adapters. Gated, absent and constant commands exercise
the production gate's body observations. Exemption and declaration-independent
claims remain independent policy evidence, checked in both directions. Schema
controls still reject malformed policy records; separate sink-corruption
controls pin the body accessor for shapes the delivery types cannot emit. No
behavioral control depends on a production row's guessed writer name.

`owned-fixtures.nix`, included by that fixture suite and the delivery-layer
checks, evaluates real runtime entries on both backends. Shared files without
ledgers, undeclared writers, conflicting methods, copy-ro/document pairings and
document path/format mismatches require exact diagnostics and corrected healthy
declarations. These complement the command-body controls; they do not replace
them or retroactively establish the order of historical matrix derivation.

### Generated delivery matrix

`config/ai-delivery.nix` remains a pure `{lib}` import. Its schema and consumer
facts are hand-authored; physical writer records come from the committed
`config/ai-delivery-generated.nix`. The partition requires every matrix cell
exactly once across derived and hand-authored rows. Absence reasons, package
wrappers, input associations and behavioral probes remain independent of the
observed delivery implementation.

`checks/ai-delivery/generate.nix` evaluates populated specimens at default
config directories. It reads typed files and activation ledgers, resolves
methods with the runtime's rule, and uses the router's backend naming. Recursive
skills use the real leaf walk. Shared devenv AGENTS.md currently comes from the
typed `ai.internal.files` owner. Package wrappers have no file entry. Kimchi's
`trust.json` (`ai.kimchi.projectTrust`) is a user-scope trust store, not a
portable surface, so the specimen maps it to no cell. Codex's
`app-server-daemon/settings.json` holds daemon configuration
(`native.daemonSettings`), not a portable surface, and maps to no cell either.

The production gate compares live absence against hand-authored gaps in both
directions. Its three body arms stay; derived names make the first arm's name
agreement a tautology, not a stronger check. Empty-declaration survival and body
variation still discriminate.

Regeneration evaluates the check set, and the check set asserts the committed
matrix, so a change that moves a cell (a runtime joining the layer, say) cannot
regenerate through the check attribute alone: bypass the `ai-delivery` and
`ai-delivery-fixtures` asserts and the partition assertion in a scratch tree,
build the observer, and restore them before committing.

Regenerate the data with
`nix build .#checks.x86_64-linux.ai-delivery-generated.generated --no-link --print-out-paths`,
copy the printed output to `config/ai-delivery-generated.nix`, then run
`treefmt config/ai-delivery-generated.nix`. The `ai-delivery-generated` check
regenerates and requires byte identity. `file-warnings.nix` continues rebasing
the matrix's default directories onto consumer configuration; neither warning
reader imports an evaluator. The matrix's project `AGENTS.md` writer is rebased
onto the key the runtime's record declares in `sharedAgentsMd`, which the
builder publishes in `ai.internal.agentsMdTargets`, never onto
`context.filename`: Kimchi's names its Home Manager harness file, while its
devenv factory always writes the project-root `AGENTS.md`. Codex, Kimchi and
Kiro all default to that one path, so the manifest folds every writer's options
per path; a first-wins map named only `ai.codex.*` for text Kimchi supplied.

### Layer location map

- L1 options and L1→L2 expansion → `lib/ai/sharedOptions.nix`
- L2b options (CLI-generic) and L2b→L3 expansion →
  `lib/ai/app/mkBackendTransform.nix` (`lib/ai/app/default.nix` selects it once
  per backend). That includes `agentsDir`, declared for every runtime with the
  agents pool, whose suffixes come from the record's `agentsDirSuffixes`
  (default `.md`). It also includes `native.agents`, declared for a record that
  supplies `agentNativeType` and `agentTransformer` and joined to the record's
  own `native.*` options. `poolOptions.<pool>` is merged over the builder's
  declaration of `agentsDir`, `environmentVariables` or `lspServers`, so a
  runtime states only its own description. The `agents` description takes no
  override: the record's `agentsDescriptionSuffix` is the only per-runtime hook
  for it, appended to the builder's text so the shared sentences stay in one
  place. The builder reads `poolOptions` by pool name, so
  `lib/ai/app/checkRecord.nix` rejects any other key, in `mkRuntime` and again
  in the transform: `agents`, a pool outside `environmentVariables` and
  `lspServers`, one the record's `supportedPools` omits, or `agentsDir` without
  `agents`. It also rejects `agentNativeType` without `agentTransformer` or the
  reverse, either one, `agentsDirSuffixes` or `agentsDescriptionSuffix` without
  the agents pool, and an empty or non-string `agentsDirSuffixes`. The native
  pair is tested for presence, so an explicit null counts as set.
- L2b options (CLI-specific, like Claude's `hookScriptsDir`) →
  `packages/<pkg>/lib/mk<Cli>.nix`
- L2↔L3 replacement/suppression filtering → transform (`aiCommon.mergePool` plus
  the rule enable filter)
- managed MCP proxy ownership, validation, and systemd unit aggregation →
  `lib/ai/sharedOptions.nix` + `lib/ai/mcpProxy.nix`
- per-scope package ownership guard → `checks/module-provenance/helpers.nix`
- L4 per-runtime routing/rendering into `ai.<runtime>.files` →
  `packages/<pkg>/lib/mk<Cli>.nix`
- L4 shared AGENTS.md contributions → the record's `sharedAgentsMd` callback,
  which returns the key, the rules under that runtime's own policy (Codex and
  Kimchi every rule; Kiro only unscoped always-on rules), optional `index`
  entries, an optional build-time `maxBytes`, and nothing else: the builder
  reads those by name, so `checkRecord.nix` rejects a missing `key` or any other
  field. The optional `hasOnDemandIndex` bit selects the general rule-index
  heading from routed trigger data rather than rendered Markdown. Codex and
  Kimchi list a scoped rule that names `references` as an index entry (its globs
  plus links to those documents) and inline every other rule, a scoped one
  behind a prose scope note. `agentsmd.renderKeyed` writes the general
  `## Rule index` when that bit is set and `## Path-scoped rules` otherwise,
  then the inlined rules and context. A file with many scoped rules stays under
  Codex's document limit, and a long context that does not (read at the 32 KiB
  default because the raised limit is absent or untrusted) loses only its own
  tail. The builder adds the merged context and publishes it on devenv. A limit
  is published even without content, because the runtime reads the file whoever
  wrote it. Codex's launcher checks actual truncation independently, on either
  backend and in any repo; there is no shell-entry window notice. The Markdown
  formatter handles the generated layout (one blank line between units and after
  each rule comment, one glob or link per index line) before the tree is
  installed.
- L4 unit paths → the record's optional `contentTargets` callback,
  `{context?; rules?}`: the path each context and rule unit lands in, built from
  the same bindings the delivery uses. `delivery-warnings.nix` warns for a unit
  whose final file is switched off or replaced (no `content._generated`);
  `checkRecord.nix` rejects a stray field.
- L4 shared AGENTS.md rendering and public-entry arbitration into the hidden
  single-owner map → `lib/ai/app/sharedAgentsMd.nix`, which lowers that map
  through the devenv adapter as the pseudo-runtime `internal` (a read-only copy
  by default, written by `ai:agents-md:materialize`)
- B7 public file-option declaration and runtime enable gate →
  `lib/ai/app/mkBackendTransform.nix`
- L5 generic backend lowering → `lib/ai/deliver.nix` (the router) and
  `lib/ai/adapters/{hm,devenv}.nix`, called from
  `lib/ai/app/mkBackendTransform.nix`. `lib/ai/runtime-files.nix` keeps the
  map's validation and the shape one entry takes in a native file sink.

### Adding a new concern X

1. Add L2 option `ai.<X>` in `lib/ai/sharedOptions.nix`.
2. Add per-CLI L3 option `ai.<cli>.<X>` in the transform baseline, gated on the
   pool, with a `poolOptions` override slot for per-runtime descriptions or
   types. Declare it in each per-CLI factory only when the shape itself differs.
3. Add `X` to `supportedPools` only on app records whose delivery `config`
   consumes it. The normalized `settings` pool follows the same rule: a runtime
   with no lossless target for any field (Kiro) leaves it out, and one that
   lowers only some fields keeps it and warns for the rest.
4. Add L4 routing/rendering into `ai.<runtime>.files` in each supporting per-CLI
   factory's `config`. Declare owned outputs' ledgers under
   `ai.<runtime>.activation`; work that owns no files uses `command`.
5. Let the existing L5 router lower the surviving entry; change
   `lib/ai/deliver.nix` or an adapter only when the delivery contract itself
   changes, and never write `home.file`, `home.activation`, `files` or `tasks`
   from a factory — `module-delivery-no-new-direct-sink-writes` scans for it.
6. Wire L2↔L3 through `mergePool`, add the pool to the package-provenance guard,
   or document and test the concern's intentional non-pool composition rule
   (hooks append per-event lists).
7. (Optional) Add L1 option `ai.<X>Dir` + L1→L2 expansion.
8. (Optional) Add per-CLI L2b option `ai.<cli>.<X>Dir` + L2b→L3 expansion.
9. Add tests beside the owning package, or under the relevant root check concern
   for shared behavior, with an unsupported-runtime unknown-option control.
   Register package tests through the owner's `checks.nix` module.

### Pitfall

**Never emit runtime artifacts from L1/L2/L2b.** Those layers exist solely to
reshape data; they read no final file map or backend sink and write none either.
If you find yourself reaching for `home.file.*` in `sharedOptions.nix` or in a
transform's `config` block, something is off — route and render into the
per-runtime file map at L4, then let the generic L5 sink lower it. Managed MCP
proxy units are the explicit sidecar exception because their lifetime and
ownership cannot belong to any one runtime view; do not generalize it to emitted
client configuration.

### Why five stages instead of inline

Earlier iterations wrote emission logic inline in each branch of per-CLI config
— directly setting `home.file.".claude/rules/${name}.md".text` from the
`ai.rules` attrset. That coupled the source shape (list vs attrset, with or
without Dir-backed ingestion) to each CLI's emission. When the rules attrs grew
a `sourcePath` field and then dropped it, every CLI had to change in lockstep.
With the layered shape, new input modes (Dir helpers, filter signatures) only
touch L1/L2b; final rendering and emission stay stable.
