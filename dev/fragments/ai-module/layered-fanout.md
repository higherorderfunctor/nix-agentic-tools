## ai.\* Layered Fanout Pattern

> **Last verified:** 2026-10-30 — network `ai.proxy` lowers once and selects
> delivery per runtime; `surfaceSupport.settings.fields` limits resolved
> normalized settings; unlisted fields warn per field; shared AGENTS.md uses
> readable `.agents/rules/` child indexes, preserves runtime audiences and
> retains structured index metadata; Copilot writes named rules and unnamed
> context independently under `.github/`; non-AI owners use the same layer-1
> helper; delivery facts derive delivered and absent cells, keyed withdrawal and
> normalized gaps from option and runtime declarations; `poolOptions` covers
> `agentsDir` and `environmentVariables` only; `optionNamespaces` places
> launcher and pool options; the devenv file observer lives in ai-module and
> reads the files plan; the shared AGENTS.md composer reaches the files plan as
> the owner `internal`; Claude stages every surface, including HM `.claude.json`
> as `rw`; the files engine writes its rules copies on devenv; staged Markdown
> and raw entries are whole-content defaults; Kiro stages every surface, with
> hooks, settings and steering legacy ledgers declared outside its enable gate;
> Kimchi stages every surface, with every legacy ledger ungated; Codex stages
> every surface and declares both copy ledgers while disabled; hand rows are
> confined to the policy-only permissions surface; named CPA routing replaces
> runtime proxy defaults; Claude's `native.installMethod` and
> `native.unpinLaunchEffort` are declared for Home Manager only, so delivery
> facts carry no supplement rows; backend lowering and validation live only in
> ai-module.
>
> Full lineage: `git show ce31eaaa:dev/fragments/ai-module/layered-fanout.md`.

**Settled — do not relitigate.** User-local settings are asserted at switch.
Choose a store symlink when an in-app write fails cleanly (Codex `config.toml`),
a read-only copy when the CLI renames over its file (Kiro, Kimchi's
`mcp.json`/`permissions.json`/`trust.json` and Codex daemon settings), and a
switch-time overlay only for a mixed state file (Claude `~/.claude.json`,
Kimchi's user `config.json` and `harness/settings.json`, which carry `/login`
and `/model` state). The overlay repairs Nix-owned leaves while preserving
harness state. Kimchi's two were read-only copies from 2026-09-29 to 2026-09-30,
which locked `/login` out; do not move them back.

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
│ L4: Staged runtime output map                              │
│   ai.<cli>._generatedFiles → ai.<cli>.files (files layer 1)│
│   - text/source default; structured leaves compose         │
│   - sibling fields compose; enable suppresses entries      │
└────────────────────────────────────────────────────────────┘
                             │
                             ▼  ai-module forwarding and lowering
┌────────────────────────────────────────────────────────────┐
│ L5: Delivery (files layers 2 and 3)                        │
│   ai.files → native links: HM home.file.* / devenv files.* │
│            → files engine copies (ro, rw)                  │
│   ai.activation → HM home.activation / devenv tasks        │
└────────────────────────────────────────────────────────────┘
```

L1–L5 are fanout stages, not the files layers 1–3 of
`packages/ai-module/docs/contract.md`: L4 ends at files layer 1, and L5 is
layers 2 and 3.

The runtime record has one data-only placement field, `optionNamespaces`,
default `{}`: it maps the builder's two option groups to relative paths, and an
omitted group stays at the runtime root. `launcher` holds package, environment,
shell and their normalized inputs, plus the switch when nested; `pools` holds
every other pool option and its normalized form. Kiro sets `launcher = ["cli"]`,
so the root `ai.kiro.enable` is read-only and derived from `ai.kiro.cli.enable`.
Copilot sets `pools = ["github"]` and reserves `launcher = ["cli"]`; a record
without `defaults.package` has no launcher, so nothing is declared there and its
root `enable` stays the switch. Declarations, per-key fold defaults, callback
reads, diagnostics, policy input paths and package contributors all go through
`lib/ai/app/optionNamespaces.nix`. Callbacks still receive the shared `cfg` and
one complete `normalized` view. Native agents and every file/ledger remain at
the runtime root. Each value must be a list of nonempty strings and only the two
groups are accepted; constructor and transform both validate it. One attrset
rather than a second path field: a runtime names exactly the groups it moves.

### Rules

- **Artifact routing/rendering lives at L4; physical emission lives at L5.**
  L1/L2/L2b are pure fanout — they never touch `ai.<runtime>.files`,
  `home.file.*`, or devenv `files.*`. Managed MCP proxy declarations use the
  ordinary `ai.internal.services` owner: `sharedOptions.nix` aggregates
  declaration scopes while ai-module lowers the daemons. Only lowered client
  entries traverse this five-stage pipeline.
- **One owner per physical path.** Enabled runtime file maps supply layer-1
  claims on both backends. Disabled entries still claim their path; disabled
  owners forward nothing. Shared repository context forwards unclaimed through
  the helper's `shared` list, leaving its composer the single owner. Agreeing
  content merges; divergent content conflicts. The shared default method is
  `ro`, with consumer method overrides governed by ordinary priorities.
- **Compiled content stays lazy.** Staged Markdown and raw entries receive a
  whole-content default at layer 1. A stronger replacement discards generated
  sources unread, judged by `_contentPrio`. Codex's empty user context is
  suppressed only when generated content wins. The shared repository composer
  follows the same priority rule.
- **Structured settings contribute per-leaf defaults.** Codex settings use
  `content.value`. Adding one consumer leaf keeps generated siblings; defaulting
  the whole document would drop them.
- **Claude delivers its own files.** Agents, commands, output styles, hook
  scripts, skills, plugins, rules, context, `.claude/settings.json` and the MCP
  files are staged entries (`ai.claude._generatedFiles`) that reach the backends
  through the files layers. All reach both backends except `.claude.json`,
  consumer plugins and the MCP personal plugin (its manifest and `.mcp.json`),
  which are Home Manager only because a plugin is user-scope; devenv writes MCP
  servers to the project `.mcp.json` instead. Nothing is handed to an upstream
  Home Manager or devenv Claude module. Settings and MCP servers are
  configuration, so `.claude/settings.json` and the devenv `.mcp.json` are
  Nix-owned read-only links rather than reconciled documents, and an in-app
  change such as `/tui` does not persist. Every settings contribution goes
  through `ai.claude.native.settings`, so one entry carries the whole document.
  With a Nix-installed package that document is always written on both backends,
  because it carries the updater default; with `package = null` and nothing
  declared, none is written. The devenv `.mcp.json` still requires a non-empty
  server declaration. Claude's user-global `.claude.json` is the exception: it
  holds OAuth tokens and runtime state, so it uses `rw` on Home Manager only. It
  carries the unpin flags and `installMethod`; with no flags and a null
  `installMethod` no document is staged, and the engine still retires previous
  keys. The legacy JSON ledger is declared while disabled too.
  `activation.claude-config-mode` runs after `materialized`, even with no flags,
  stripping group and other access from regular files while Claude is enabled.
- **The CLI's write primitive picks the method.** Codex's `config.toml` is a
  store symlink on both backends: every Codex config writer writes a temporary
  beside the link's target, so an in-app save fails and the link survives
  (`chatgpt-codex-readonly-config`). Its daemon `settings.json` is the opposite
  case: Codex renames a temporary over it, which would swap a link for a real
  file and fail the next switch's link check, so it stages one `ro` JSON copy in
  the `app-server-daemon` directory. Kiro and Kimchi rename too, so their
  settings are copies as well.
- **Commands use layer 3.** Codex's skill-link migrator owns no ledger and uses
  `activation.codex-migrate-skill-links`, with `after = []` and
  `before = ["linkCheck"]` on both backends. Home Manager's outer `run` makes
  dry runs inert. Its daemon selector uses `activation.codex-daemon-select` on
  Home Manager, with `runWhenDisabled = true`. Directory skill sources keep
  `recursive = false` because Codex discovers directory symlinks.
- **devenv guards native links after pruning.** The base emits one
  `ai:files-guard` from the final native file map. It follows cleanup, prune and
  commands positioned before `linkCheck`, then precedes native file creation. It
  removes stale store-backed links and refuses foreign links or real files at
  desired link paths. The engine retires copies before this check, so a
  copy-to-link transition completes in one generation. With no native files the
  graph uses its internal linked point instead of requiring a missing
  `devenv:files` task. A failed guard prevents dependent file creation and shell
  tasks from succeeding.
- **Shared documents reconcile harness state.** Claude's `.claude.json` is a
  writable state file with Nix-owned leaves. The files engine restores declared
  keys on activation and retains native keys. Its legacy ledger name remains a
  literal upgrade contract. Kimchi stages user `config.json` and harness
  `settings.json` as `rw` too; native keys survive while declared keys return.
  Its git-token branch retains `ro` mode 0400 with an activation-time renderer,
  as does trust with the read-only default mode. Engine apply follows secret
  providers; all old Kimchi ledgers are ungated legacy declarations.
- **Kiro stages settings and hooks as read-only copies.** `cli.json` carries a
  JSON value and `mcp.json` a `run` renderer through S → R → F. Kiro's own
  writers rename a temporary over either file, which replaces a symlink and a
  0444 copy alike. A copy is still the right method: the next activation or
  shell entry backs the in-app file up and restores the declaration, while a
  symlink would block Home Manager's link check or be skipped by devenv. Home
  Manager always claims both user-global files, including the updater default
  when Nix installs the package and an empty server map when none is declared.
  With `package = null`, it adds no updater default; devenv claims a project
  file only when something is declared. `mcp.json` is 0400 with a URL secret,
  otherwise 0444. Engine apply waits for the secrets point whenever the plan
  contains a renderer: HM includes `sops-nix`, and devenv uses registered
  `secretNodes`. The renderer exports its backend root and keeps devenv's
  project-root anchor for relative secret readers. Hooks state `method = "ro"`
  because the v3 scan keeps only `isFile()` entries; the engine retires them at
  N→0. Hooks, settings and steering ledgers are ungated upgrade declarations.
  Permissions remain HM-only because Kiro never reads them from project
  `.kiro/`.
- **Claude project rules are read-only copies on devenv.** Claude's scoped-rule
  (`paths:`) loader passes `includeExternal: false` at Project scope, with no
  setting to change it (claude-code 2.1.280), so a `.claude/rules` symlink into
  the store is never read. User scope passes true. Each staged rule therefore
  states `method = {devenv = "ro"; hm = "symlink";}`: the files engine copies it
  on devenv, while Home Manager keeps its link. The old writer's
  `materialize/claude-rules.manifest` is declared as a legacy ledger from the
  devenv `migrationConfig`, so the copies it wrote drain on N→0 and on a disable
  alike.
- **Codex execpolicy rules are read-only copies on both backends.** Codex keeps
  a `rules/*.rules` entry only when `DirEntry::file_type().is_file()`, which
  does not follow symlinks, so a linked rule is skipped silently. Each staged
  rule states `method = "ro"` and `format = "raw"`; the engine owns individual
  paths, preserving Codex's native `rules/default.rules` beside them.
- **Retirement survives disable.** Every runtime's `migrationConfig` declares
  its deleted writers' `legacyLedgers` outside the enable gate. The engine
  imports them before native link checks and retires paths absent from the
  desired plan, including during a disabled owner's first upgrade. Codex
  declares execpolicy on both backends and daemon settings on Home Manager.
- **Replacement and negation at every supported L2↔L3 boundary.** Per-runtime
  entries replace same-key root entries wholesale. Nullable pools use null to
  suppress an inherited entry after the shallow merge; rules use
  `enable = false` on the replacement entry. Unsupported root requests warn and
  lower to the neutral value before this boundary; there is no L3 option. L1→L2
  and L2b→L3 use `mkDefault` so explicit entries within the same layer still win
  before cross-level composition.
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
  owner instead of creating competing runtime writers. Copilot instead writes
  unnamed context to `.github/copilot-instructions.md`; its named rules remain
  separate `.github/instructions/<name>.instructions.md` files. It never
  contributes to the shared composer.
- **Rule triggers resolve before L4.** Each runtime selects the first supported
  entry from the portable `inclusion` list through `aiCommon.resolveInclusion`.
  `fileMatch` consumes `matcher` and becomes native routing metadata where one
  exists or explicit prose for flat AGENTS.md consumers. Codex and Kimchi can
  route `auto` and `manual` only through a non-empty `references` index. In the
  shared devenv AGENTS.md, Codex and Kimchi contribute every resolved inline or
  indexed rule; Kiro contributes only rules resolved to `always`. The keyed
  writer deduplicates identical same-key payloads and combines their sorted
  runtime audiences. A runtime-local suppression removes that runtime from the
  audience even when a sibling still contributes the rule. Audience prose is
  advisory: it does not hide bytes from readers, and shared always-on context
  remains shared.
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
- **Normalized settings share one closed schema.** Every runtime whose
  `surfaceSupport.settings` declares a non-empty backend list receives the
  `settings` submodule. Listed scalar fields resolve root versus per-runtime
  with `resolveOverride`. Listed `inference` instead copies root selection
  fields down at default priority, preserving explicit null opt-outs and
  withdrawing the opposite form when a runtime switches between instance and
  URL; its normalized value is the resolved endpoint. Unlisted normalized fields
  stay null, and native lowering stays per-runtime. Runtime-shaped passthrough
  is separate under `native.settings` and is not a normalized pool.
- `ai.proxy` is the shared network proxy; see
  `dev/fragments/ai-proxy/ai-proxy.md`.
- **Dir helpers live in `lib.ai.*`**, not in the module layer. They're pure
  (`path → attrset`) and usable outside HM/devenv.
- **Per-file emission only.** A Dir option never takes a destination dir over
  wholesale — other derivations (or consumer's own direct `home.file.*` calls)
  can always contribute alongside.
- **Key identity is preserved.** If a file is named `foo.md` in the source dir,
  the L2 key is `foo` (the helper strips known suffixes before emitting the key,
  and the per-CLI L4 emission re-appends). This is why the `.md.md` doubled-
  extension bug from 2026-04-21 is structurally impossible now.

### Delivery facts

`config/ai-delivery.nix` is a pure `{lib}` import of the facts the warning
readers keep: `lib/ai/delivery-warnings.nix`, `checks/ai-warnings` and the
Kimchi and peer-communication module evaluations. It needs no module evaluation
or package set. `config/ai-delivery-schema.nix` reads `sharedSurfaceOptions`
through its internal `sharedSurfaces` option default; that declaration's
`leafFields` metadata supplies the input paths for plain option trees without
adding policy branches for individual surfaces. Keyed withdrawal is metadata on
those same root declarations. Permissions is the sole policy-only surface
because it inventories native policy vocabularies, with no normalized root
translation.

Each surface, runtime and backend cell is one row, `delivered` or
`notApplicable` with a reason. Runtime `surfaceSupport` derives whole-surface
absences and their reasons. A native writer can exist alongside an unavailable
normalized pool (Kiro hooks and settings, `nativeWriters` in
`config/ai-delivery-facts.nix`); that cell stays delivered and gains the absence
as a diagnostic child. Static record gaps and undeclared normalized settings
fields project into diagnostic children too, using the shared fallback reasons.
Gaps requiring keyed entries, effective scalar selection, predicates or dynamic
reasons remain record-only diagnostics. Hand rows state native-only absences on
the policy-only permissions surface; a hand row on a shared surface fails naming
the cell, because it would replace the row derived from the runtime record.
Input associations are consumer facts. An option only Home Manager can write is
declared under the record's `hm.options` instead of warning through a row:
Claude's `native.installMethod` and `native.unpinLaunchEffort` do not exist on
devenv, so setting either there is an unknown-option error.

Where a delivered file lands, and how, is the files plan's business, not these
facts'. Adding a shared surface or dropping runtime support creates absence
cells without policy edits.

### Layer location map

- L1 options and L1→L2 expansion → `lib/ai/sharedOptions.nix`
- L2b options (CLI-generic) and L2b→L3 expansion →
  `lib/ai/app/mkBackendTransform.nix` (`lib/ai/app/default.nix` selects it once
  per backend). That includes `agentsDir`, declared for every runtime with the
  agents pool, whose suffixes come from the record's `agentsDirSuffixes`
  (default `.md`). It also includes `native.agents`, declared for a record that
  supplies `agentNativeType` and `agentTransformer` and joined to the record's
  own `native.*` options. `poolOptions.<pool>` is merged over the builder's
  declaration of `agentsDir` or `environmentVariables`, so a runtime states only
  its own description. The `agents` description takes no override: the record's
  `agentsDescriptionSuffix` is the only per-runtime hook for it, appended to the
  builder's text so the shared sentences stay in one place. The builder reads
  `poolOptions` by pool name, so `lib/ai/app/checkRecord.nix` rejects any other
  key, in `mkRuntime` and again in the transform: `agents`, a pool other than
  `environmentVariables`, one the record's `surfaceSupport` omits, or
  `agentsDir` without `agents`. It also rejects `agentNativeType` without
  `agentTransformer` or the reverse, either one, `agentsDirSuffixes` or
  `agentsDescriptionSuffix` without the agents pool, an empty or non-string
  `agentsDirSuffixes`. The native pair is tested for presence, so an explicit
  null counts as set. `ai.settings.inference` selects `instance` + `clientKey`
  or external `url` + `key`; runtime support is declared through
  `surfaceSupport.settings.fields` (see
  `dev/fragments/ai-inference/ai-inference.md`).
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
  entries (resolved inclusion, matcher, references and description), an optional
  build-time `maxBytes`, and nothing else: the builder reads those by name, so
  `checkRecord.nix` rejects a missing `key` or any other field. The optional
  `hasOnDemandIndex` bit selects the general rule-index heading from routed
  trigger data rather than rendered Markdown. Codex and Kimchi list a scoped
  rule that names `references` as an index entry (its globs plus links to those
  documents) and inline every other rule, a scoped one behind a prose scope
  note. Copilot has no `sharedAgentsMd` callback: context and rules use its own
  generated tree. `agentsmd.renderKeyed` writes the general `## Rule index` when
  that bit is set and `## Path-scoped rules` otherwise, then the inlined rules
  and context. The builder supplies an audience map from each contributing
  runtime's name; equal index/body payloads deduplicate while audiences combine,
  and divergent payloads still fail. Index entries and inline bodies name their
  intended runtimes. An index whose entries all share one audience names it once
  above the entries; mixed audiences remain per-entry. The fallback index tells
  runtimes with native rule injection to use that injected guidance instead of
  following additional references. Standalone runtime documents omit these
  shared-target audience notes. A file with many scoped rules stays under
  Codex's document limit; named inline rules and context still count against
  that limit. A long context follows the index and inline rules, so truncation
  reaches its tail first. The builder adds the merged context and publishes it
  on devenv. A limit is published even without content, because the runtime
  reads the file whoever wrote it. Codex's launcher checks actual truncation
  independently, on either backend and in any repo; there is no shell-entry
  window notice. The Markdown formatter handles the generated layout (one blank
  line between units and after each rule comment, one glob or link per index
  line) before the tree is installed. The shared composer groups two or more
  `fileMatch` entries only when every reference in each entry is a plain
  relative file path under one common parent directory and the rendered root
  index becomes strictly shorter. It uses sorted matcher unions for root
  pointers, dropping only patterns already covered by a literal `directory/**`
  prefix; children retain each original matcher and audience. Auto/manual rules,
  mixed-parent references, URLs and anchors stay at root. Child names live under
  `.agents/rules/` beside the target and use readable names derived from the
  common source directory; path collisions retain distinct identities. They are
  never an automatically loaded `AGENTS.md`. Links are rebased relative to their
  containing file, including nested custom targets. There is one child tier and
  no grouping option. Children use the existing internal generated tree and
  read-only file ownership; replacing or disabling the root disables its
  generated children, and removing a group retires its files. Child/root target
  collisions fail rather than overwrite. Tier selection reads index metadata,
  never discarded context or inline rule sources.
- L4 unit paths → the record's optional `contentTargets` callback,
  `{context?; rules?}`: the path each context and rule unit lands in, built from
  the same bindings the delivery uses. `delivery-warnings.nix` warns for a unit
  whose final file is switched off or replaced (selected content and priority);
  `checkRecord.nix` rejects a stray field.
- L4 shared AGENTS.md rendering and public-entry arbitration into the
  single-owner plan → `lib/ai/app/sharedAgentsMd.nix`, which stages the winner
  and forwards it through the ai-module layer-1 helper as the owner `internal`
  (a read-only copy by default, written by the files engine)
- B7 public file-option declaration and runtime enable gate →
  `packages/ai-module/lib/runtime.nix`
- L5 generic backend lowering and entry validation →
  `packages/ai-module/lib/files/default.nix`, `lib/files/backend.nix` and
  `lib/lower-{hm,devenv}.nix` under that owner; the runtime factory renders and
  stages entries without writing native sinks.

The shared-target audience notes are routing instructions, not access controls:
every reader still receives the same bytes. GitHub's
[custom-instructions support table](https://docs.github.com/en/copilot/reference/custom-instructions-support)
lists both path-specific instructions and AGENTS.md for code review; its
[repository instructions guide](https://docs.github.com/en/copilot/how-tos/copilot-on-github/customize-copilot/add-custom-instructions/add-repository-instructions)
documents automatic use by default (verified 2026-10-25). A reader with native
rules must not treat the shared fallback index as permission to reload rules its
own configuration omitted.

### Adding a new concern X

1. Add L2 option `ai.<X>` to `sharedSurfaceOptions` in
   `lib/ai/sharedOptions.nix`. This is also the shared fanout registration:
   decomposition automatically warns for every enabled runtime whose
   `surfaceSupport` does not consume `X`; no per-gap policy row is needed.
   Declare backend-specific gaps and partially delivered fields on the runtime
   record.
2. Add per-CLI L3 option `ai.<cli>.<X>` in the transform baseline, gated on the
   pool, with a `poolOptions` override slot for per-runtime descriptions or
   types. Declare it in each per-CLI factory only when the shape itself differs.
3. Declare `surfaceSupport.X` only on app records whose delivery `config`
   consumes it. The normalized `settings` pool follows the same rule: a runtime
   with no lossless target for any field (Kiro) leaves it out, and one that
   lowers only some fields lists those names in
   `surfaceSupport.settings.fields`. New fields warn for every runtime that has
   not listed them.
4. Add L4 routing/rendering into `ai.<runtime>._generatedFiles` in each
   supporting per-CLI factory's `config`. State content, format, method and
   surface; commands use `ai.<runtime>.activation`.
5. Let ai-module lower the entries; change its backend only when the delivery
   contract changes. Never write native sinks from an owner module or factory;
   see the contract's Owner rule.
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
proxies use `ai.internal.services` with explicit scoped claims because their
lifetime and ownership span runtime views. Native daemon sinks remain owned by
ai-module.

### Why five stages instead of inline

Earlier iterations wrote emission logic inline in each branch of per-CLI config
— directly setting `home.file.".claude/rules/${name}.md".text` from the
`ai.rules` attrset. That coupled the source shape (list vs attrset, with or
without Dir-backed ingestion) to each CLI's emission. When the rules attrs grew
a `sourcePath` field and then dropped it, every CLI had to change in lockstep.
With the layered shape, new input modes (Dir helpers, filter signatures) only
touch L1/L2b; final rendering and emission stay stable.
