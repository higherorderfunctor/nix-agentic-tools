## Architecture Fragments

> **Last verified:** 2026-07-27 (commit pending — the worked
> registration example is now explicitly fictional, so it can no
> longer drift out of sync with a real category's `scopes`; it
> previously named `ai-clis` and `claude-code` and had gone stale
> against both. Prior 2026-07-27, that example stopped teaching
> `packages/ai-clis/**`, a directory that does not exist; prior
> 2026-07-24, the `packagePaths` + `devFragmentNames` registries
> dissolved into `config.fragments.categories`).

This repo ships path-scoped architecture fragments as dev-only
context for agents working on it. They are SEPARATE from the
published consumer-facing content. Three location flavors are
supported by `dev/generate.nix`:

- `dev/fragments/<category>/<name>.md` (default
  `location = "dev"`) — orientation and topic-scoped categories
  not tied to a single package. `dev/fragments/monorepo/`
  specifically holds the always-loaded orientation, composed into
  `common.md` and the equivalent for each ecosystem.
- `packages/<pkg>/docs/<name>.md` (`location = "package"`) —
  co-located with the package whose abstractions it documents.
- `devshell/<group>/docs/<name>.md` (`location = "devshell"`) —
  co-located with a devshell module.

Scope globs (which files the fragment loads for) live separately
in `config.fragments.categories.<category>.scopes` (declared in
`config/fragment-categories.nix`) and are independent of where the
markdown source lives on disk.

Each scoped fragment emits per-ecosystem frontmatter via the
`fragments-ai.passthru.transforms` pipeline:

- Claude: `.claude/rules/<name>.md` with `paths:` YAML list
- Copilot: `.github/instructions/<name>.instructions.md` with
  `applyTo:` comma-joined globs
- Kiro: `.kiro/steering/<name>.md` with `inclusion: fileMatch`
  and an array `fileMatchPattern:`
- Codex / AGENTS.md: orientation only (no scoped fragments).
  Deep-dive architecture content lives in the per-ecosystem
  scoped files above.
  AGENTS.md used to concatenate every scoped fragment flat, but
  that bloated it to ~2k lines; Phase 2.4 trimmed it to just the
  monorepo orientation content (commit c4f4aff).

### Maintenance is mandatory

**When you make changes that alter the shape of any abstraction a
scoped fragment describes, update the fragment in the same commit.**
Out-of-date architecture fragments actively mislead future sessions
and are worse than no fragment at all.

Each scoped fragment opens with a `Last verified: <date> (commit
<hash>)` marker. If that marker predates your change to the area
the fragment scopes, the fragment is stale. Stop and update it
before landing the commit — in the same commit, not a follow-up.

This is not an etiquette rule. Research on LLM context shows
out-of-date instructions degrade task success more than missing
instructions. A lie is worse than silence.

### When to add a new fragment

Add a fragment when you encounter a piece of non-inferable
knowledge during debugging or implementation — something the
next session would burn a lot of tokens rediscovering. Examples
of the kind of content worth writing down:

- **Why** a non-obvious design decision was made (trade-offs,
  abandoned alternatives)
- **Cross-cutting invariants** that span multiple files
- **Shapes of abstractions** (fanout patterns, wrapper chains,
  activation lifecycles)
- **Known pitfalls** (subtle bugs, gotchas, migrations in flight)
- **Debugging entry points** (what to grep, what to eval)

Do NOT add fragments for content that is:

- Discoverable by reading the code itself in under 10 seconds
- Already covered by existing code comments (DRY)
- A restatement of function signatures, file paths, or line numbers
- Ephemeral (in-progress state goes in plan.md or memory, not
  fragments)

Target under 150 lines per fragment. If a topic outgrows that,
split by sub-concern with tighter scopes.

### Generator registration

New fragments are registered in `config/fragment-categories.nix`
under `config.fragments.categories`. The attribute key is the
category (which becomes the output filename for scoped Claude
rules, Copilot instructions, and Kiro steering). Each category is
one record with two fields: `scopes` (the path globs it loads for)
and `sources` (the markdown fragments composed into it). A
`sources` entry is either a bare string (legacy dev/fragments/
path) or an attrset with an explicit location:

```nix
# ILLUSTRATIVE ONLY — neither category below exists. Real rows
# live in config/fragment-categories.nix; read that file for them.
config.fragments.categories = {
  example-dev-sourced = {
    scopes = ["overlays/example.nix" "packages/example/**"];
    sources = [
      # bare string: location="dev", dir defaults to the category key
      "packaging-guide"
      # → dev/fragments/example-dev-sourced/packaging-guide.md
    ];
  };
  example-co-located = {
    scopes = ["packages/example/**"];
    sources = [
      {
        location = "package";
        name = "example-wrapper";
        # dir overrides the category key; null (the default) would
        # look under packages/example-co-located/docs/ instead
        dir = "example";
        # → packages/example/docs/example-wrapper.md
      }
    ];
  };
};
```

Both categories above are **fictional on purpose.** A worked
example that names a real category is a standing drift liability:
it goes stale every time that category's `scopes` change, and the
maintenance rule above will not catch it, because re-pointing a
glob does not alter the _shape_ this snippet teaches. That is
exactly how this snippet rotted once — it taught
`packages/ai-clis/**`, a directory that no longer exists. Keep the
example about the record's shape and let
`config/fragment-categories.nix` be the source of real rows.

`scopes` is a Nix list of globs, and `null` means always-loaded
(what the `monorepo` orientation category uses). The option itself
is declared in `lib/fragments-registry.nix`; `dev/generate.nix`
merges the two with `lib.evalModules` and reads the result. The
transforms handle per-ecosystem emission — do not hand-format
frontmatter.

After adding or editing fragments, run
`devenv tasks run --mode before generate:instructions` to
regenerate steering files for all ecosystems.
