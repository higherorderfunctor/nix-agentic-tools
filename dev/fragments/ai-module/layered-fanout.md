## ai.\* Layered Fanout Pattern

> **Last verified:** 2026-04-21 (commit pending — refactor of
> ai-factory-collision plan §4). If you add a new Dir option or
> change how per-file Dir expansion fans through the layers,
> update this fragment in the same commit.

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
│   ai.<X> = attrsOf <itemModule>                            │
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
│   ai.<cli>.<X> = attrsOf <itemModule>                      │
│   - merged with L2 via mergeWithCollisionCheck             │
│   - collision-as-failure at the L2↔L3 boundary             │
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

- **Emission logic lives ONLY at L4.** L1/L2/L2b are pure
  fanout — they never touch `home.file.*` or `files.*`.
- **Collision-as-failure at every layer boundary.** The
  mergeWithCollisionCheck helper fires on the L2↔L3 boundary
  inside each CLI's transform. L1→L2 and L2b→L3 use
  `mkDefault` so explicit entries within the same layer still
  win (that's a fanout, not a cross-layer collision).
- **Dir helpers live in `lib.ai.*`**, not in the module layer.
  They're pure (`path → attrset`) and usable outside HM/devenv.
- **Per-file emission only.** A Dir option never takes a
  destination dir over wholesale — other derivations (or
  consumer's own direct `home.file.*` calls) can always
  contribute alongside.
- **Key identity is preserved.** If a file is named `foo.md`
  in the source dir, the L2 key is `foo` (the helper strips
  known suffixes before emitting the key, and the per-CLI L4
  emission re-appends). This is why the `.md.md` doubled-
  extension bug from 2026-04-21 is structurally impossible
  now.

### Layer location map

- L1 options and L1→L2 expansion → `lib/ai/sharedOptions.nix`
- L2b options (CLI-generic) and L2b→L3 expansion →
  `lib/ai/app/{hmTransform,devenvTransform}.nix`
- L2b options (CLI-specific, like Claude's `agentsDir` or
  `hooksDir`) → `packages/<pkg>/lib/mk<Cli>.nix`
- L2↔L3 collision check → transform (`collisionAssertions`)
- L4 emission → `packages/<pkg>/lib/mk<Cli>.nix`

### Adding a new concern X

1. Add L2 option `ai.<X>` in `lib/ai/sharedOptions.nix`.
2. Add per-CLI L3 option `ai.<cli>.<X>` in the transform
   baseline (if every supported CLI handles it the same way)
   or in each per-CLI factory (if the shape differs).
3. Add L4 emission in each per-CLI factory's customConfig.
4. Wire the L2↔L3 merge through mergeWithCollisionCheck in
   both transforms.
5. (Optional) Add L1 option `ai.<X>Dir` + L1→L2 expansion.
6. (Optional) Add per-CLI L2b option `ai.<cli>.<X>Dir` +
   L2b→L3 expansion.
7. Add tests in `checks/module-eval.nix` for every new
   surface.

### Pitfall

**Never emit from L1/L2/L2b.** Those layers exist solely to
reshape data; they read nothing from `config.home.file.*` /
`config.files.*` and write nothing there either. If you find
yourself reaching for `home.file.*` in `sharedOptions.nix` or
in a transform's `config` block, something is off — drop the
contribution into the per-CLI factory's L4 emission.

### Why 4 layers instead of inline

Earlier iterations wrote emission logic inline in each branch
of per-CLI config — directly setting `home.file.".claude/
rules/${name}.md".text` from the `ai.rules` attrset. That
coupled the source shape (list vs attrset, with or without
Dir-backed ingestion) to each CLI's emission. When the rules
attrs grew a `sourcePath` field and then dropped it, every
CLI had to change in lockstep. With the 4-layer shape, new
input modes (Dir helpers, filter signatures) only touch L1/L2b;
emission stays stable.
