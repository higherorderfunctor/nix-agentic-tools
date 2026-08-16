## ai.\* Layered Fanout Pattern

> **Last verified:** 2026-08-15 (commit pending — L2↔L3 keyed pools now use
> atomic per-runtime replacement with null tombstones, while package ownership
> collisions are checked by definition provenance within each scope). Prior:
> 2026-08-15 (commit pending — typed context is the composition exception: root
> and runtime content concatenate root-first into one runtime-named artifact.
> Keyed rules retain collision semantics and lower their normalized matcher at
> L4; repository-local AGENTS.md consumers share a keyed, byte-deduplicating
> writer). Prior: 2026-08-15 (commit pending — L2 root pools now cross into L3
> only for runtimes whose app record lists that pool in `supportedPools`;
> unsupported root fanout degrades and the L2b/L3 options are absent. The closed
> normalized `settings` schema is deliberately listed by all five runtimes even
> when a particular field lowers only for a subset). Prior: 2026-08-01 (commit
> pending — records the portable hooks exception: per-event matcher-group lists
> append instead of key-colliding, and agents may carry a typed semantic
> record). Prior: 2026-04-21 (commit pending — refactor of ai-factory-collision
> plan §4). If you add a new Dir option or change how per-file Dir expansion
> fans through the layers, update this fragment in the same commit.

### Canonical 4-layer shape

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
                             ▼  translation + emission
┌────────────────────────────────────────────────────────────┐
│ L4: Emission (factory internal; not a user surface)        │
│   - HM: home.file.* / programs.<cli>.* delegation          │
│   - Devenv: files.* emission                               │
│   - Transformer frontmatter per ecosystem                  │
└────────────────────────────────────────────────────────────┘
```

### Rules

- **Emission logic lives ONLY at L4.** L1/L2/L2b are pure fanout — they never
  touch `home.file.*` or `files.*`.
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
  typed `text`-XOR-`source` records, not pool entries. Their content composes
  root-first into the runtime's `context.filename`.
- **Rule matchers lower only at L4.** `matcher = null` is always-on; a non-empty
  glob list becomes native routing metadata where one exists and explicit prose
  for flat AGENTS.md consumers. The shared devenv AGENTS.md writer admits only
  unscoped units and deduplicates byte-identical same-key contributions.
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
  `lib/ai/app/{hmTransform,devenvTransform}.nix`
- L2b options (CLI-specific, like Claude's `agentsDir` or `hookScriptsDir`) →
  `packages/<pkg>/lib/mk<Cli>.nix`
- L2↔L3 replacement/null filtering → transform (`aiCommon.mergePool`)
- per-scope package ownership guard → `checks/module-eval.nix`
- L4 emission → `packages/<pkg>/lib/mk<Cli>.nix`

### Adding a new concern X

1. Add L2 option `ai.<X>` in `lib/ai/sharedOptions.nix`.
2. Add per-CLI L3 option `ai.<cli>.<X>` in the transform baseline (if every
   supported CLI handles it the same way) or in each per-CLI factory (if the
   shape differs).
3. Add `X` to `supportedPools` only on app records whose callbacks consume it.
   The uniform normalized `settings` schema is the explicit exception: every
   runtime declares it, while each field's native lowering may be narrower.
4. Add L4 emission in each supporting per-CLI factory's customConfig.
5. Wire L2↔L3 through `mergePool`, add the pool to the package-provenance guard,
   or document and test the concern's intentional non-pool composition rule
   (hooks append per-event lists).
6. (Optional) Add L1 option `ai.<X>Dir` + L1→L2 expansion.
7. (Optional) Add per-CLI L2b option `ai.<cli>.<X>Dir` + L2b→L3 expansion.
8. Add tests in `checks/module-eval.nix` for every new surface and at least one
   unsupported-runtime unknown-option control.

### Pitfall

**Never emit from L1/L2/L2b.** Those layers exist solely to reshape data; they
read nothing from `config.home.file.*` / `config.files.*` and write nothing
there either. If you find yourself reaching for `home.file.*` in
`sharedOptions.nix` or in a transform's `config` block, something is off — drop
the contribution into the per-CLI factory's L4 emission.

### Why 4 layers instead of inline

Earlier iterations wrote emission logic inline in each branch of per-CLI config
— directly setting `home.file.".claude/rules/${name}.md".text` from the
`ai.rules` attrset. That coupled the source shape (list vs attrset, with or
without Dir-backed ingestion) to each CLI's emission. When the rules attrs grew
a `sourcePath` field and then dropped it, every CLI had to change in lockstep.
With the 4-layer shape, new input modes (Dir helpers, filter signatures) only
touch L1/L2b; emission stays stable.
