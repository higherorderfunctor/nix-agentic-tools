# Steering fragments research (Checkpoint 2)

Research into LLM steering-file best practices, per-ecosystem
scoping mechanisms, and context-management trade-offs. Informs
the Checkpoint 3 design spec.

## Core finding: context rot is the primary failure mode

- **Lost-in-the-middle effect**: models attend well to start/end
  of context, poorly to middle — 30%+ accuracy drops on content
  buried in the middle of long contexts.
  ([Morph LLM — Context Rot](https://www.morphllm.com/context-rot))
- **40% context utilization ceiling** is the practical recommended
  cap; beyond this, LLMs start hallucinating edits to wrong files.
  ([Latitude — Context Engineering for Coding Agents](https://latitude-blog.ghost.io/blog/context-engineering-guide-coding-agents/))
- **LLM-generated context files REDUCE task success by ~3% on
  average** and inflate steps/tokens by 20%+. Only human-written
  context files showed marginal gains (~4% success boost), and
  only when limited to "non-inferable details."
  ([InfoQ — New Research Reassesses AGENTS.md Value](https://www.infoq.com/news/2026/03/agents-context-file-value-review/),
  [DAPLab — Your AI Agent Doesn't Care About Your README](https://daplab.cs.columbia.edu/general/2026/03/31/your-ai-agent-doesnt-care-about-your-readme.html))
- **Recommendation from researchers**: "Omit LLM-generated context
  files entirely and limit human-written instructions to
  non-inferable details, such as highly specific tooling or
  custom build commands."
- **Workflow reference**: [Addy Osmani — My LLM Coding Workflow Going Into 2026](https://addyosmani.com/blog/ai-coding-workflow/)

## Implications for this repo

1. **Ruthlessly concrete.** Every fragment must justify its
   tokens. If a fact is derivable from reading the code in <10s,
   it does NOT belong in a fragment.
2. **<150 lines per fragment** (Claude docs say <200 per
   CLAUDE.md; Copilot says <2 pages). Split aggressively.
3. **Minimum always-loaded.** Only the absolute orientation goes
   in always-loaded files. Everything else must be path-scoped.
4. **Self-maintenance is essential.** Out-of-date fragments are
   WORSE than missing fragments — they actively mislead. Baked
   into design.

## Per-ecosystem scoping mechanisms

All three major ecosystems converge on: markdown files + frontmatter
with path-based scoping. Keys differ; semantics align.

### Claude Code (`.claude/rules/*.md`)

- **Default**: loaded always, same priority as `.claude/CLAUDE.md`
- **Scoped via `paths:` frontmatter** (YAML array of glob patterns)
- Path-scoped rules "trigger when Claude reads files matching the
  pattern, not on every tool use"
- Subdirectory organization supported (`rules/frontend/x.md`,
  `rules/backend/y.md`)
- Skills are SEPARATE and load on invocation or semantic match —
  not the same as rules
- **Size guidance**: "target under 200 lines per CLAUDE.md file.
  Longer files consume more context and reduce adherence."
- Symlinks supported for shared/company rules
- ([Claude Code — Memory](https://code.claude.com/docs/en/memory))

Example:

```markdown
---
paths:
  - "src/api/**/*.ts"
---

# API rules
```

### GitHub Copilot (`.github/instructions/*.instructions.md`)

- Files must match naming pattern `NAME.instructions.md`
- Subdirectory organization supported
- **Scoped via `applyTo:` frontmatter** (comma-separated glob string)
- Automatic loading when Copilot works on matching files
- **Size guidance**: "no longer than 2 pages"
- ([GitHub Docs — Repository Custom Instructions](https://docs.github.com/en/copilot/how-tos/configure-custom-instructions/add-repository-instructions))

Example:

```markdown
---
applyTo: "app/models/**/*.rb,lib/models/**/*.rb"
---

# Rails model rules
```

### Kiro (`.kiro/steering/*.md`)

- 4 inclusion modes via `inclusion:` frontmatter:
  - `always` — every interaction (default)
  - `fileMatch` with `fileMatchPattern` — conditional on match
  - `manual` — on-demand via `#steering-file-name` or slash
  - `auto` + `description` — skill-like semantic activation
- Can link to live workspace files: `#[[file:path]]`
- Workspace scope (`.kiro/steering/`) vs global (`~/.kiro/steering/`)
- ([Kiro — Steering](https://kiro.dev/docs/steering/))

Example:

```markdown
---
inclusion: fileMatch
fileMatchPattern: "components/**/*.tsx"
---

# React component rules
```

### Codex / AGENTS.md

- Single flat file, no path scoping natively
- Already supported by our `fragments-ai.passthru.transforms.agentsmd`
- Concatenation-based; consumers read the whole thing
- ([agents.md — AGENTS.md standard](https://agents.md/))

## Convergence: what this means for our generator

The existing `dev/generate.nix` already handles the per-ecosystem
fanout through `fragments-ai.passthru.transforms.{claude,copilot,kiro,agentsmd}`.
What each transform does with `paths` metadata:

- `claude`: emits `paths: [...]` frontmatter
- `copilot`: emits `applyTo: "..."` frontmatter (joining globs with commas)
- `kiro`: emits `inclusion: fileMatch` + `fileMatchPattern: "..."`
- `agentsmd`: ignores scoping, concatenates body

We should verify these transforms actually produce the right
frontmatter for each ecosystem. If not, that's a prerequisite fix
before the architecture fragments work.

## Design decisions locked by this research

### 1. Always-loaded vs scoped split

**Always-loaded set is as minimal as possible.** Only content that
every session genuinely needs:

- The repo's top-level layout (lib/ modules/ packages/ flake /
  what lives where)
- A pointer to scoped fragments (table of contents)
- Skill routing reminder (already in CLAUDE.md)
- Self-maintenance directive (one paragraph)

**Everything else is path-scoped.** Loaded only when the agent
touches files in that scope.

Target: the always-loaded architecture content should be **one
fragment, ~100-150 lines max**, added to the existing `monorepo`
category.

### 2. Fragment granularity

**<150 lines per fragment.** If a topic outgrows that, split by
sub-concern. Prefer many small scoped fragments over few large ones.

Rationale:

- Matches Claude Code's <200 line guidance with a safety margin
- Matches Copilot's <2 pages
- Matches the 40% context utilization ceiling for path-scoped
  files that co-load
- Smaller fragments are easier to keep up to date
- Smaller fragments are easier for a future maintenance skill to
  programmatically verify/update

### 3. Non-inferable information only

Fragments must focus on what the CODE ITSELF DOES NOT TELL YOU:

**Include:**

- Why something is the way it is (design decisions, trade-offs)
- Cross-cutting invariants (config parity rules, cache-hit parity)
- Warnings about pitfalls (known bugs, migrations in flight)
- Shapes of abstractions (how the ai module fans out, how buddy
  activation works end-to-end — things that span multiple files)
- Debugging entry points (what command to run, what to check)

**Exclude:**

- Function signatures (grep gets them faster)
- File paths/line numbers (they decay, grep finds them)
- Repeated from code comments (DRY — code comments are closer)
- Anything `/init` or the model could figure out alone
- Ephemeral state (HITL progress, backlog — those are plan.md/memory)

### 4. Self-maintenance is a design requirement

When architectural changes happen, stale fragments ACTIVELY MISLEAD.
The research is clear: wrong context is worse than no context.

Three layers of maintenance:

**Layer A — inline in always-loaded orientation:**

A short paragraph (5-10 lines) in the always-loaded `architecture-map`
fragment stating: "When you make architectural changes, check
`dev/fragments/architecture/*` and `modules/*/fragments/dev/*` and
`packages/*/fragments/dev/*` for stale content. Update or delete
anything that no longer reflects reality. Out-of-date fragments
are worse than missing ones."

**Layer B — per-fragment timestamp / last-verified marker:**

Each scoped fragment's body opens with a short "last-verified"
marker that an LLM reviewing the file can compare against git log
to detect drift:

```markdown
---
paths: ["modules/claude-code-buddy/**"]
---

> **Last verified against code:** 2026-04-07 (commit da18b10).
> If you touch the buddy activation flow and this fragment isn't
> updated in the same commit, stop and fix it.
```

**Layer C — future `/dev-update-fragments` skill (BACKLOG):**

A skill that runs on demand ("dev, check if fragments match code")
which:

- Reads every fragment's `paths:` frontmatter
- For each, finds matching files that changed since the
  last-verified commit
- Presents a diff review prompt for each stale fragment
- Updates last-verified markers after human approval

This is a backlog item. The fragment STRUCTURE enables it without
needing the skill to exist day 1. The `paths:` frontmatter already
supplies the data the skill would need.

### 5. DRY across ecosystems AND docsite

Single markdown source feeds:

- `.claude/rules/<cat>.md` (path-scoped rules)
- `.github/instructions/<cat>.instructions.md` (path-scoped)
- `.kiro/steering/<cat>.md` (path-scoped fileMatch)
- `AGENTS.md` (concatenated flat)
- **Docsite reference page** (mdbook) — potentially under a new
  "Contributing / Architecture" section

The docsite transform (`fragments-docs.passthru.transforms`) needs
to render the same markdown as an mdbook page. Frontmatter (paths,
applyTo, inclusion) is stripped or converted to tags. Body is
identical. Single source of truth.

**Decision for Checkpoint 7:** verify that `fragments-docs.passthru.transforms`
can consume dev-only fragments (it currently consumes published
fragments from content packages like coding-standards). If not,
extend it. Don't duplicate content.

## Anti-patterns to avoid

From the research:

- Don't `/init` a CLAUDE.md and check it in untouched — the
  research shows LLM-generated files actively degrade performance
- Don't paraphrase code into natural language — that's dilution
- Don't mirror information across fragments — that's the context
  rot amplifier
- Don't gate fragments on "when you might touch" broad globs —
  tight scopes reduce false loads
- Don't write fragments that can be replaced by a `/init` rerun —
  those are by definition inferable and therefore wasteful

## Open questions going into Checkpoint 3

1. **Dumping-ground co-location**: do new scoped fragments live
   in `packages/<pkg>/fragments/dev/*.md` and
   `modules/<subdir>/fragments/dev/*.md`, or stay in
   `dev/fragments/<cat>/*.md`?
   Research doesn't answer this — it's an organizational choice
   the user already leans toward co-location. Checkpoint 3 locks
   this with a migration plan for new fragments only (not existing).
2. **Docsite rendering of dev fragments**: does `fragments-docs`
   already handle dev-only sources, or is this new wiring?
   Needs code inspection before Checkpoint 7.
3. **Verify the existing transforms emit correct ecosystem
   frontmatter** (`paths:` for claude, `applyTo:` for copilot,
   `inclusion:` for kiro). If they do, zero new machinery. If
   they don't, prerequisite fix.

## Sources

- [Claude Code — Memory / CLAUDE.md](https://code.claude.com/docs/en/memory)
- [Claude Code — Setup](https://code.claude.com/docs/en/setup)
- [GitHub Docs — Repository Custom Instructions](https://docs.github.com/en/copilot/how-tos/configure-custom-instructions/add-repository-instructions)
- [Kiro — Steering](https://kiro.dev/docs/steering/)
- [agents.md — AGENTS.md standard](https://agents.md/)
- [Morph LLM — Context Rot](https://www.morphllm.com/context-rot)
- [Latitude — Context Engineering for Coding Agents](https://latitude-blog.ghost.io/blog/context-engineering-guide-coding-agents/)
- [InfoQ — New Research Reassesses AGENTS.md Value](https://www.infoq.com/news/2026/03/agents-context-file-value-review/)
- [DAPLab — Your AI Agent Doesn't Care About Your README](https://daplab.cs.columbia.edu/general/2026/03/31/your-ai-agent-doesnt-care-about-your-readme.html)
- [Addy Osmani — My LLM Coding Workflow Going Into 2026](https://addyosmani.com/blog/ai-coding-workflow/)
