## Architecture Fragments

> **Last verified:** 2026-09-25 — package categories live in owner registries;
> `dev/generate.nix` turns them into `ai.rules` and `ai.*` writes every
> runtime's files.

This repo ships path-scoped architecture fragments as dev-only context for
agents working on it. They are SEPARATE from the published consumer-facing
content. Three location flavors are supported by `dev/generate.nix`:

- `dev/fragments/<category>/<name>.md` (default `location = "dev"`) —
  orientation and topic-scoped categories not tied to a single package.
  `dev/fragments/monorepo/` specifically holds the always-loaded orientation,
  delivered to every runtime as `ai.context`.
- `packages/<pkg>/docs/<name>.md` (`location = "package"`) — co-located with the
  package whose abstractions it documents.
- `devshell/<group>/docs/<name>.md` (`location = "devshell"`) — co-located with
  a devshell module.

Scope globs (which files the fragment loads for) live separately in
`config.fragments.categories.<category>.scopes` (composed from owner
`registry.nix` files and `config/fragment-categories.nix`) and are independent
of where the markdown source lives on disk.

Each scoped category becomes one `ai.rules` entry (`dev/ai.nix`) whose `matcher`
is its scopes and whose `references` are its source documents, and `ai.*` writes
it per runtime through the `lib/ai/transformers/` pipeline:

- Claude: `.claude/rules/<name>.md` with `paths:` YAML list
- Copilot: `.github/instructions/<name>.instructions.md` with `applyTo:`
  comma-joined globs
- Kiro: `.kiro/steering/<name>.md` with `inclusion: fileMatch` and an array
  `fileMatchPattern:`
- Codex / AGENTS.md: always-loaded orientation plus a compact
  `## Path-scoped rules` index. Codex has no glob-scoped instruction primitive,
  so matching remains a manual progressive-disclosure step: the index maps the
  same registry scopes to the authoritative source documents. AGENTS.md used to
  concatenate every scoped fragment body, but that bloated it to ~2k lines;
  Phase 2.4 removed the bodies (commit c4f4aff), and `ai.*` renders a scoped
  rule that names `references` as an index entry for the same reason.

The source fragments are authoritative. Every runtime file above is a generated
projection that `ai.*` writes: AGENTS.md and `.github/` are committed, the
Claude and Kiro ones are gitignored and written on devenv shell entry. Never
edit a projection directly; the next shell entry, or the drift check, undoes it.
A `devenv shell` or direnv reload regenerates the local files after source or
registry changes.

### Maintenance is mandatory

**When you make changes that alter the shape of any abstraction a scoped
fragment describes, update the fragment in the same commit.** Out-of-date
architecture fragments actively mislead future sessions and are worse than no
fragment at all.

Each scoped fragment opens with a `Last verified: <date> (commit <hash>)`
marker. If that marker predates your change to the area the fragment scopes, the
fragment is stale. Stop and update it before landing the commit — in the same
commit, not a follow-up.

This is not an etiquette rule. Research on LLM context shows out-of-date
instructions degrade task success more than missing instructions. A lie is worse
than silence.

### The marker is ONE entry, not a changelog

Update the `Last verified` marker in place. **Do not append the old entry as a
`Prior:`.** These fragments are LLM context: one source fans out to Claude,
Codex, Copilot and Kiro, so every byte is paid four times, on every turn that
matches the scope.

The habit of chaining `Prior:` entries grew to **82 KB across 31 fragments — 15%
of all fragment text** — and it broke a consumer outright: github.com's Copilot
PR reviewer began failing with `Prompt too big after adding system message`
before it read a line of any diff.

**The body is the record.** A correction that was applied to the body needs no
changelog entry — the body already says the true thing, and the entry only
restates it at four times the cost. That is what nearly all of those 82 KB were.

Keep exactly two things beyond the current entry, and only when they earn it:

- A **`Settled — do not relitigate`** bullet, for an approach that was TRIED and
  REJECTED, or a measurement that would otherwise be re-derived wrongly. Name
  the rejected thing and why it failed, keep the evidence (dates, PR numbers,
  counts), and stop. This is the one thing git does not give you cheaply,
  because reading a diff tells you WHAT changed and not what was ruled out.
- A **git ref** to the last fuller version, when the reasoning is worth being
  able to re-read: `` `git show <hash>:<path>` ``. One ref, not a chain.

Everything else — re-verification with no change, restatements of what a commit
did, dates with no claim attached — is dropped. Deleting it loses nothing: it is
in the file's history, which is what history is for.

### When to add a new fragment

Add a fragment when you encounter a piece of non-inferable knowledge during
debugging or implementation — something the next session would burn a lot of
tokens rediscovering. Examples of the kind of content worth writing down:

- **Why** a non-obvious design decision was made (trade-offs, abandoned
  alternatives)
- **Cross-cutting invariants** that span multiple files
- **Shapes of abstractions** (fanout patterns, wrapper chains, activation
  lifecycles)
- **Known pitfalls** (subtle bugs, gotchas, migrations in flight)
- **Debugging entry points** (what to grep, what to eval)

Do NOT add fragments for content that is:

- Discoverable by reading the code itself in under 10 seconds
- Already covered by existing code comments (DRY)
- A restatement of function signatures, file paths, or line numbers
- Ephemeral (in-progress state goes in plan.md or memory, not fragments)

Target under 150 lines per fragment. If a topic outgrows that, split by
sub-concern with tighter scopes.

### Generator registration

New fragments are registered under `config.fragments.categories`: use the
owner's `registry.nix` for package-specific categories and
`config/fragment-categories.nix` for workspace/shared categories. The attribute
key is the category (which becomes the output filename for scoped Claude rules,
Copilot instructions, and Kiro steering). Each category is one record with two
fields: `scopes` (the path globs it loads for) and `sources` (the markdown
fragments composed into it). A `sources` entry is either a bare string (legacy
dev/fragments/ path) or an attrset with an explicit location:

```nix
# ILLUSTRATIVE ONLY — neither category below exists. Real rows
# live in config/fragment-categories.nix; read that file for them.
config.fragments.categories = {
  example-dev-sourced = {
    scopes = ["packages/example/**"];
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

Both categories above are **fictional on purpose.** A worked example that names
a real category is a standing drift liability: it goes stale every time that
category's `scopes` change, and the maintenance rule above will not catch it,
because re-pointing a glob does not alter the _shape_ this snippet teaches. That
is exactly how this snippet rotted once — it taught `packages/ai-clis/**`, a
directory that no longer exists. Keep the example about the record's shape and
let `config/fragment-categories.nix` be the source of real rows.

`scopes` is a Nix list of globs, and `null` means always-loaded (what the
`monorepo` orientation category uses). The option itself is declared in
`lib/fragments-registry.nix`; `lib/facets/registry.nix` composes the
contributions with `lib.evalModules`, and `dev/generate.nix` reads its result
into the `context` and `rules` that `dev/ai.nix` hands to `ai.*`. The transforms
handle per-ecosystem emission — do not hand-format frontmatter.

After adding or editing fragments, run
`devenv tasks run --mode before generate:all` to regenerate instruction and
repo-document projections. `--mode before` is load-bearing: without it devenv
runs an aggregate without its dependency leaves.
