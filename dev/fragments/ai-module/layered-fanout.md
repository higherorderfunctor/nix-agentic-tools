## ai.\* Layered Fanout Pattern

> **Last verified:** 2026-09-21 — context content uses the shared text-source
> type and arbitrates `text` against `source` by module priority.
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
│   ai.<X> = attrsOf (nullOr <itemModule>)                   │
│   - cross-ecosystem pool                                   │
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
│   ai.<cli>.<X> = attrsOf (nullOr <itemModule>)             │
│   - exists only when the app record supports pool X        │
│   - same-key value atomically replaces L2                  │
│   - same-key null suppresses the inherited L2 entry        │
└────────────────────────────────────────────────────────────┘
                             │
                             ▼  routing + native rendering
┌────────────────────────────────────────────────────────────┐
│ L4: Final runtime output map                               │
│   ai.<cli>.files = attrsOf (nullOr { text|source; ... })    │
│   - generated whole entries use mkDefault                  │
│   - ordinary entries replace; null suppresses              │
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
- **Replacement and negation at every supported L2↔L3 boundary.** Per-runtime
  entries replace same-key root entries wholesale; null suppresses an inherited
  entry after the shallow merge. Unsupported root fanout degrades before this
  boundary and has no L3 option. L1→L2 and L2b→L3 use `mkDefault` so explicit
  entries within the same layer still win before cross-level composition.
- **One package owner per key and scope.** Definition-provenance checks reject
  two packages claiming one root key or one per-runtime key. A root key and its
  runtime replacement are different scopes and do not collide.
- **List-valued lifecycle hooks append.** `ai.hooks.<Event>` matcher groups run
  before `ai.<cli>.hooks.<Event>` groups. This is intentional composition, not
  an attrset-entry collision; only the exact portable Claude/Codex event
  vocabulary is accepted at L2.
- **Context content concatenates.** `ai.context` and `ai.<cli>.context` are
  typed `text`/`source` records, not pool entries. Different priorities
  arbitrate the effective text; one priority setting both fields fails. Their
  content composes root-first into the runtime's `context.filename`. A
  structural `hasMergedContext` bit gates the generated default without reading
  composed sources; rendered bytes remain lazy until that default survives B7.
- **Rule matchers lower only before L4.** `matcher = null` is always-on; a
  non-empty glob list becomes native routing metadata where one exists and
  explicit prose for flat AGENTS.md consumers. In the shared devenv AGENTS.md,
  Codex contributes both unscoped rules and scoped rules degraded to prose; Kiro
  contributes only unscoped always-on rules. The keyed writer deduplicates
  byte-identical same-key contributions.
- **Normalized settings are a uniform scalar-field surface.** Every runtime
  declares the same closed `settings` submodule. Each field resolves root versus
  per-runtime with `resolveOverride`; native lowering remains per-runtime and
  may support only a subset of fields. Runtime-shaped passthrough is separate
  under `nativeSettings` and is not a normalized pool.
- **Dir helpers live in `lib.ai.*`**, not in the module layer. They're pure
  (`path → attrset`) and usable outside HM/devenv.
- **Per-file emission only.** A Dir option never takes a destination dir over
  wholesale — other derivations (or consumer's own direct `home.file.*` calls)
  can always contribute alongside.
- **Key identity is preserved.** If a file is named `foo.md` in the source dir,
  the L2 key is `foo` (the helper strips known suffixes before emitting the key,
  and the per-CLI L4 emission re-appends). This is why the `.md.md` doubled-
  extension bug from 2026-04-21 is structurally impossible now.

### Layer location map

- L1 options and L1→L2 expansion → `lib/ai/sharedOptions.nix`
- L2b options (CLI-generic) and L2b→L3 expansion →
  `lib/ai/app/mkBackendTransform.nix` (the HM/devenv transform files are thin
  selectors)
- L2b options (CLI-specific, like Claude's `agentsDir` or `hookScriptsDir`) →
  `packages/<pkg>/lib/mk<Cli>.nix`
- L2↔L3 replacement/null filtering → transform (`aiCommon.mergePool`)
- managed MCP proxy ownership, validation, and systemd unit aggregation →
  `lib/ai/sharedOptions.nix` + `lib/ai/mcpProxy.nix`
- per-scope package ownership guard → `checks/module-provenance/helpers.nix`
- L4 per-runtime routing/rendering into `ai.<runtime>.files` →
  `packages/<pkg>/lib/mk<Cli>.nix`
- L4 shared AGENTS.md rendering and public-entry arbitration into the hidden
  single-owner map → `lib/ai/app/sharedAgentsMd.nix`
- B7 public file-option declaration and runtime enable gate →
  `lib/ai/app/mkBackendTransform.nix`
- L5 generic backend lowering → `lib/ai/runtime-files.nix`, called from
  `lib/ai/app/mkBackendTransform.nix`

### Adding a new concern X

1. Add L2 option `ai.<X>` in `lib/ai/sharedOptions.nix`.
2. Add per-CLI L3 option `ai.<cli>.<X>` in the transform baseline (if every
   supported CLI handles it the same way) or in each per-CLI factory (if the
   shape differs).
3. Add `X` to `supportedPools` only on app records whose callbacks consume it.
   The uniform normalized `settings` schema is the explicit exception: every
   runtime declares it, while each field's native lowering may be narrower.
4. Add L4 routing/rendering into `ai.<runtime>.files` in each supporting per-CLI
   factory's customConfig. Lifecycle-owned non-literal outputs remain explicit
   exceptions rather than bypassing the static map silently.
5. Let the existing L5 sink lower the surviving entry; change
   `runtime-files.nix` only when the common literal-file contract itself
   changes.
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
