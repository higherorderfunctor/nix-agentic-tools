## Architecture Fragments

This repo ships path-scoped architecture fragments as dev-only
context for agents working on it. They are SEPARATE from the
published consumer-facing content. Locations:

- `dev/fragments/monorepo/` — always-loaded orientation (this
  category, composed into `common.md` and the equivalent for
  each ecosystem)
- `packages/<pkg>/fragments/dev/` — scoped to files under
  `packages/<pkg>/**`, co-located with the code they document
- `modules/<subdir>/fragments/dev/` — scoped to files under
  `modules/<subdir>/**`, co-located with the code they document

Each scoped fragment emits per-ecosystem frontmatter via the
`fragments-ai.passthru.transforms` pipeline:

- Claude: `.claude/rules/<name>.md` with `paths:` YAML list
- Copilot: `.github/instructions/<name>.instructions.md` with
  `applyTo:` comma-joined globs
- Kiro: `.kiro/steering/<name>.md` with `inclusion: fileMatch`
  and an array `fileMatchPattern:`
- Codex / AGENTS.md: flat concatenation (no scoping)

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

New fragments are registered in `dev/generate.nix` under
`devFragmentNames`. The attribute key is the category (which
becomes the output filename for scoped Claude rules, Copilot
instructions, and Kiro steering). Each entry is either a bare
string (legacy dev/fragments/ path) or an attrset with an
explicit location:

```nix
devFragmentNames.ai-clis = [
  "packaging-guide"  # legacy: dev/fragments/ai-clis/packaging-guide.md
  {
    location = "package";
    name = "claude-code-wrapper";
    # dir defaults to "ai-clis"
    # → packages/ai-clis/fragments/dev/claude-code-wrapper.md
  }
];
```

Scope globs for each category live in `packagePaths` as Nix lists.
`null` means always-loaded. The transforms handle per-ecosystem
emission — do not hand-format frontmatter.

After adding or editing fragments, run
`devenv tasks run --mode before generate:instructions` to
regenerate steering files for all ecosystems.
