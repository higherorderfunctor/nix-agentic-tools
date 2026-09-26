## ai.\* Layered Fanout Pattern

> **Last verified:** 2026-09-25 — L5 is the delivery router plus one adapter per
> backend; every runtime describes delivery once through the record-level
> `config`, which `mkRuntime` makes the only delivery callback, and the delivery
> matrix is generated from the layer for every runtime's files. Normalized pools
> carry only a text-source record's winning arm. Claude's devenv rules and
> Codex's execpolicy rules are read-only copies whose writers survive a disable.
> Copilot reconciles its user settings.json on HM and the repository
> `.github/copilot/settings.json` on devenv. Kiro excludes the normalized
> `settings` pool. Native file settings live under `ai.<runtime>.native`. The
> builder publishes each record's devenv shared AGENTS.md contribution, and its
> key in `ai.internal.agentsMdTargets`, from the record's `sharedAgentsMd`.
> Claude's `.claude.json` has an ungated mode-narrowing command writer beside
> its unpin ledger. The builder declares the per-runtime `agents`,
> `environmentVariables` and `lspServers` options and an opt-in `agentsDir`; a
> record's `poolOptions` carries only what differs. `checkRecord.nix` rejects a
> `poolOptions` key the builder would not read and a stray field in the
> `sharedAgentsMd` result. Every reconciled document is one
> `helpers.mkReconciledDocument` call. A shared AGENTS.md contribution may carry
> `index` entries: Codex renders a scoped rule that names `references` as a
> path-scoped index entry instead of inlining its body. The shared AGENTS.md map
> lowers through the router as `internal`, as a read-only copy.
>
> Full lineage: `git show ce31eaaa:dev/fragments/ai-module/layered-fanout.md`.

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
- **Structured documents contribute ordinary leaves.** Codex HM settings and
  Copilot MCP/LSP use `content.value` at ordinary priority. Adding one leaf
  keeps generated siblings, including leaves already recorded by Codex's ledger;
  defaulting the whole content would silently retire those siblings. Text and
  source content retain their whole-content defaults.
- **Delegated surfaces still have delivery entries.** Claude's Home Manager
  agents, hook scripts, skills, LSP and MCP maps use `method = "upstream"` with
  sinks under `programs.claude-code`. Settings, permissions and typed hooks
  share the `.claude/settings.json` entry. On devenv that entry delegates to
  `files.".claude/settings.json".json`, so upstream's hooks still merge into the
  same document. The router aliases definitions so upstream overrides still beat
  generated defaults and the host owns list merging. Declare each sink path
  once: repeating a list-valued `sink` on every content contribution
  concatenates the path segments. The backend's supported roots remain explicit;
  devenv's `claude.code.mcpServers` integration is outside those roots and
  retains its native delegation. Claude's user-global `.claude.json` instead
  claims the existing JSON ledger under `claudeUnpinLaunchEffort`; its writer
  survives empty declarations and remains Home Manager only. That writer keeps
  whatever mode it finds, whether or not it rewrites the file, so an ungated
  `claudeConfigMode` command writer is the only thing that narrows the
  token-bearing file to owner-only, on every activation.
- **Writers belong beside the file map.** Codex's user `config.toml` claims a
  TOML ledger because the trust prompt writes native state there; project config
  remains a generated source. Its skill-link migrator owns no ledger and uses
  `activation.<name>.command`: HM needs `after = []` and
  `before = ["linkCheck"]`, while devenv uses the default file/shell edges.
  Commands omit a final newline because the router supplies it, along with
  strict mode and a scoped subshell. Directory skill sources keep
  `recursive = false` because Codex discovers directory symlinks. Named profiles
  retain their lockout assertion and user-layer destination: HM describes
  whole-file sources in the delivery map, while devenv retains its guarded
  host-directory materializer through a command writer named
  `ai:codex:materialize-profiles`. The materializer still owns its
  Git-common-directory manifest and lock.
- **Shared documents reconcile where the CLI writes them.** Kiro's cli.json
  states `facts.harnessWrites = true` and declares its writer unconditionally
  while enabled. The adapter runs the same bundle on HM activation or devenv
  shell entry. Backend-keyed `entry` preserves HM names while giving devenv its
  required namespace, such as `ai:kiro:settings-merge`. Devenv uses
  `$DEVENV_ROOT` and `$DEVENV_STATE/nix-agentic-tools`, with verification in
  `enterTest`. Empty declarations retain their writers so prior leaves can be
  retracted. Existing file modes and unowned leaves survive; a new file is 0600.
  The fact is per backend when the CLI writes only one copy. Copilot writes both
  of its settings copies (`/model`, `/settings` and their `--repo` forms), so
  one writer, `copilotSettingsMerge`, reconciles the user settings.json on HM
  and the repository `.github/copilot/settings.json` on devenv. Codex's project
  config remains a static source because its native writer is user-scoped. Each
  such document is one `helpers.mkReconciledDocument` call
  (`lib/ai/hm-helpers.nix`), which emits the writer with its ledger and the file
  entry that names both, so the pair cannot drift. Its `entry` and `ledger` stay
  literals at the call site: both are upgrade contracts.
- **A document ledger reserves its path against symlink delivery.** Both
  `method` and `methodFor` overrides are rejected on HM/devenv when the resolved
  symlink destination still has a declared JSON/TOML ledger, even without a
  claimant. Empty retirement preserves the regular document and native siblings;
  it cannot safely hand that path to a link writer. Ordinary empty retirement
  and Kiro's transitions between owned MCP modes remain supported.
- **Owned entries must agree with their ledgers.** `copy-ro` requires a
  directory ledger. A document claimant's path and format must exactly match its
  JSON/TOML ledger: the ledger controls the actual destination and codec, so a
  mismatch would redirect output or silently change its ownership semantics.
- **Kiro keeps one MCP writer for both modes.** Both historical ledgers are
  declared together; the selected file claims one and the other retracts. Merge
  keeps `content.run` even with zero servers; empty overwrite has no claimant.
  URL-secret modes remain 0400/0600, otherwise 0444/0644. Only this writer waits
  for secrets. The devenv renderer keeps its project-root anchor for relative
  secret readers. Hooks state `facts.symlinkReadable = false` because the v3
  scan keeps only `isFile()` entries, and their writer survives N→0. Permissions
  remain HM-only because Kiro never reads them from project `.kiro/`.
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
- **Rule matchers lower only before L4.** `matcher = null` is always-on; a
  non-empty glob list becomes native routing metadata where one exists and
  explicit prose for flat AGENTS.md consumers. In the shared devenv AGENTS.md,
  Codex contributes both unscoped rules and scoped rules degraded to prose; Kiro
  contributes only unscoped always-on rules. The keyed writer deduplicates
  byte-identical same-key contributions.
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
exactly once across derived and hand-authored rows. Absence reasons, upstream
contracts, package wrappers, input associations and behavioral probes remain
independent of the observed delivery implementation.

`checks/ai-delivery/generate.nix` evaluates populated specimens at default
config directories. It reads typed files and activation ledgers, resolves
methods with the runtime's rule, and uses the router's backend naming. Recursive
skills use the real leaf walk. Shared devenv AGENTS.md currently comes from the
typed `ai.internal.files` owner; Claude's native devenv MCP integration is
observed at its existing upstream destination. Package wrappers have no file
entry. Kimchi's `trust.json` (`ai.kimchi.projectTrust`) is a user-scope trust
store, not a portable surface, so the specimen maps it to no cell.

The production gate compares live absence against hand-authored gaps in both
directions and verifies upstream sink correspondence. Its three body arms stay;
derived names make the first arm's name agreement a tautology, not a stronger
check. Empty-declaration survival and body variation still discriminate. Kiro
MCP's two strategies keep independent probes, including both HM phases.

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
  per backend). That includes `agentsDir`, declared only for a record whose
  `poolOptions` names it: Codex consumes `agents` with no directory form.
  `poolOptions.<pool>` is merged over the builder's declaration, so a runtime
  states only its own description or a native type (Codex's agents). The builder
  reads `poolOptions` by pool name, so `lib/ai/app/checkRecord.nix` rejects any
  other key, in `mkRuntime` and again in the transform: a pool outside `agents`,
  `environmentVariables` and `lspServers`, one the record's `supportedPools`
  omits, or `agentsDir` without `agents`.
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
  which returns the key, the rules under that runtime's own policy (Codex every
  rule; Kiro only unscoped always-on rules; Kimchi none), optional `index`
  entries and an optional `maxBytes`, and nothing else: the builder reads those
  by name, so `checkRecord.nix` rejects a missing `key` or any other field.
  Codex lists a scoped rule that names `references` as an index entry (its globs
  plus links to those documents) and inlines every other rule, a scoped one
  behind a prose scope note. `agentsmd.renderKeyed` writes the context, then the
  `## Path-scoped rules` index, then the inlined rules, so a file with many
  scoped rules stays under Codex's document limit. The builder adds the merged
  context and publishes it on devenv. A limit is published even without content,
  because the runtime reads the file whoever wrote it. The layout is the
  Markdown formatter's fixed point (one blank line between units and after each
  rule comment, one glob or link per index line), so a committed copy survives a
  formatter pass.
- L4 unit paths → the record's optional `contentTargets` callback,
  `{context?; rules?}`: the path each context and rule unit lands in, built from
  the same bindings the delivery uses. `delivery-warnings.nix` warns for a unit
  whose final file is switched off; `checkRecord.nix` rejects a stray field.
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
