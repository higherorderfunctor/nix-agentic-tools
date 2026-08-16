## ai.\* Dir Helpers

> **Last verified:** 2026-08-15 (commit pending — directory-generated
> per-runtime entries now replace or null-suppress same-key root entries under
> the normalized keyed-pool contract). Prior: 2026-04-21 (commit pending —
> refactor of ai-factory-collision plan §4 / commits 4–7). If you add a new
> `*FromDir` helper or change the polymorphic input shape or the filter
> signature and this fragment isn't updated in the same commit, stop and fix it.

### The helpers

All live in `lib/ai/dir-helpers.nix`, re-exported under `lib.ai.*`:

- `rulesFromDir` — directory of `.md` files → `attrsOf { text = <path> }`. Key
  is basename minus `.md`.
- `skillsFromDir` — directory-of-directories → `attrsOf path`. Key is the subdir
  name unchanged.
- `agentsFromDir` — directory of `.md` files → `attrsOf path`. Key is basename
  minus `.md`. Claude + Copilot only.
- `hooksFromDir` — directory of regular files → `attrsOf lines` (via
  `readFile`). Key is the filename unchanged (hooks are typically extensionless
  shell scripts). Claude-only.

### Polymorphic input

Per the refactor plan §3.5 — every Dir option is either:

- A bare Nix path literal, or
- A submodule `{ path, filter? }` where `filter : name → bool`.

The option type lives in `lib/ai/ai-common.nix:dirOptionType` and is shared
across sharedOptions and the per-CLI baselines.

### Filter signature

`name → bool` — name only, NOT `(name, kind) → bool` or `(entry) → bool`. Covers
the real use cases (e.g. "exclude .bk files", "only keep a specific entry")
without over-engineering. User directive: "just name is fine on the filter".

Default filters per helper:

| Helper          | Default filter                 |
| --------------- | ------------------------------ |
| `rulesFromDir`  | `name: hasSuffix ".md" name`   |
| `skillsFromDir` | `_: true` (every subdir)       |
| `agentsFromDir` | `name: hasSuffix ".md" name`   |
| `hooksFromDir`  | `_: true` (every regular file) |

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
dir, which a consumer may also populate directly from
`programs.claude-code.marketplaces` or via a separate module.

### Pitfall — path type strictness

The helpers use `builtins.readDir cfg.path` and compute per-file paths as
`cfg.path + "/${name}"`. Path addition preserves the `"path"` type when
`cfg.path` is a literal, so downstream consumers that strict-check `lib.isPath`
still see a path (not a store-path string). Do NOT replace the path literal in
consumer code with `builtins.path { path = ...; }` or a `builtins.filterSource`
result — those return strings and silently break upstream HM's `mkSkillEntry`
and similar strict-check paths. See `hm-modules/module-conventions.md` on "Nix
path types".
