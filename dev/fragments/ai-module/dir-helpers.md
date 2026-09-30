## ai.\* Dir Helpers

> **Last verified:** 2026-09-30 — root `ai.agentsDir` is gone; every
> `ai.<runtime>.agentsDir` expands through `agentsFromDirWith` (exported; there
> is no `agentsFromDir`) into raw per-runtime agent entries, Kiro taking `.json`
> and `.md` and Codex `.toml`. Only top-level regular files with those suffixes
> are expanded; subdirectories and other files are not delivered, and two files
> with one stem throw. A Dir option takes a path-like string too: a store string
> stays one and any other absolute string becomes a path literal, so every
> expanded entry is a path or a store string. A null `filter` means the helper's
> default. Directory-generated per-runtime entries replace or null-suppress
> same-key root entries under the normalized keyed-pool contract; see "Consumer
> patterns" below. The builder expands every per-runtime Dir option, `agentsDir`
> included, outside the enable gate. The path-type pitfall is about strict
> `lib.isPath` checks. Full lineage:
> `git show bfb6b663:dev/fragments/ai-module/dir-helpers.md`.

### The helpers

All live in `lib/ai/dir-helpers.nix`, re-exported under `lib.ai.*`:

- `rulesFromDir` — directory of `.md` files → `attrsOf { text = <path> }`. Key
  is basename minus `.md`.
- `skillsFromDir` — directory-of-directories → `attrsOf path`. Key is the subdir
  name unchanged.
- `agentsFromDirWith suffixes` — directory of native agent files → an attrset of
  paths, keeping top-level regular files that end in one of `suffixes`. Key is
  basename minus that suffix; two files with one stem throw. This is the
  exported helper. The builder expands `ai.<runtime>.agentsDir` for every
  runtime with the agents pool, with the record's `agentsDirSuffixes` (default
  `.md`; Kiro `.json` and `.md`, Codex `.toml`). The paths are raw
  `ai.<runtime>.agents` entries at `mkDefault`, so they blend with named entries
  and a named entry at the same key wins. There is no root `ai.agentsDir`: root
  `ai.agents` takes only normalized records.
- `hooksFromDir` — directory of regular files → `attrsOf lines` (via
  `readFile`). Key is the filename unchanged (hooks are typically extensionless
  shell scripts). Claude-only.

### Polymorphic input

Per the refactor plan §3.5 — every Dir option is either:

- A bare Nix path literal, or a path-like string or derivation (a flake input's
  `"${src}/agents"`), or
- A submodule `{ path, filter? }` where `filter : name → bool`. A null `filter`
  (the default) uses the helper's own default below.

`resolveDirArg` keeps a store-path string or derivation as its store string and
turns any other absolute string (`"${config.devenv.root}/agents"`) into a path
literal. Every expanded entry is then a path or a store string, which every
writer's `isPathLike` copies. A non-store string entry would instead ship its
own path as the file's text.

The option type lives in `lib/ai/ai-common.nix:dirOptionType` and is shared
across sharedOptions and the per-CLI baselines.

### Filter signature

`name → bool` — name only, NOT `(name, kind) → bool` or `(entry) → bool`. Covers
the real use cases (e.g. "exclude .bk files", "only keep a specific entry")
without over-engineering. User directive: "just name is fine on the filter".

Default filters per helper:

| Helper                       | Default filter                 |
| ---------------------------- | ------------------------------ |
| `rulesFromDir`               | `name: hasSuffix ".md" name`   |
| `skillsFromDir`              | `_: true` (every subdir)       |
| `agentsFromDirWith suffixes` | name ends in one of `suffixes` |
| `hooksFromDir`               | `_: true` (every regular file) |

### Consumer patterns

Point at a directory and every file becomes an entry:

```nix
ai.kiro.rulesDir = ./kiro-config/steering;
```

Exclude backup files with a custom filter:

```nix
ai.kiro.rulesDir = {
  path = ./kiro-config/steering;
  filter = name: !(lib.hasSuffix ".bk" name);
};
```

Mix Dir-based and explicit entries freely. They merge through `mkDefault`, so
explicit entries win within the same layer. A resulting per-runtime entry then
replaces a same-key root entry wholesale; an explicit per-runtime null
suppresses the inherited root entry.

### Why pure-eval only

Earlier iterations let a `sourcePath` field on `ruleModule` trigger out-of-store
symlink emission for live-edit. Rolled back in the same refactor (plan §3.3).
Rationale: devenv already covers the live-iteration use case, and pure-eval
keeps the factory easier to reason about. All rule/agent/skill/hook content
bakes into the store at eval time with transformer frontmatter injected.

### Why per-file (not wholesale symlink)

A `home.file.<dir>.source = <path>` with `recursive = true` takes the
destination dir over — no other derivation can contribute files alongside.
Per-file expansion preserves that escape hatch. This matters in Claude's rules
dir, which a consumer may also populate directly or via a separate module.

### Pitfall — path type strictness

The helpers use `builtins.readDir cfg.path` and compute per-file paths as
`cfg.path + "/${name}"`. Path addition preserves the `"path"` type when
`cfg.path` is a literal, so downstream consumers that strict-check `lib.isPath`
still see a path (not a store-path string). A string or derivation directory
yields store-path strings instead, which is why every writer tests `isPathLike`.
Do NOT replace the path literal in consumer code with
`builtins.path { path = ...; }` or a `builtins.filterSource` result — those
return strings and silently break every strict `lib.isPath` check downstream.
See `hm-modules/module-conventions.md` on "Nix path types".
