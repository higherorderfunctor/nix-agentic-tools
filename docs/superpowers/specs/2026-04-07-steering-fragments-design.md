# Steering Fragments Design Spec

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build scoped, self-maintaining architecture fragments that
load on demand (per-ecosystem scoping) to give future Claude/Copilot/
Kiro/Codex sessions fast access to non-inferable knowledge about how
this repo is architected, without polluting always-loaded context.

**Research input:** `dev/notes/steering-research.md` — context rot,
per-ecosystem scoping mechanisms, size budgets, self-maintenance
requirement. Read first if you haven't.

**Approach:** Minimal always-loaded orientation fragment + path-scoped
deep-dive fragments, co-located with their subject code, fanned out via
the existing fragment pipeline to all four ecosystems AND the docsite
from a single markdown source.

---

## Prerequisite bug fixes (Checkpoint 4, before any new fragment)

Verified 2026-04-07 by generating current scoped rule files — existing
multi-pattern path scoping is broken for Claude and Kiro.

### Bug 1: `dev/generate.nix` passes pre-quoted comma-joined strings

```nix
# CURRENT (broken)
packagePaths = {
  ai-clis = ''"modules/copilot-cli/**,modules/kiro-cli/**,packages/ai-clis/**"'';
  mcp-servers = ''"modules/mcp-servers/**,packages/mcp-servers/**"'';
  monorepo = null;
  stacked-workflows = ''"packages/stacked-workflows/**"'';
};
```

The string `''"a,b,c"''` is a Nix string literal containing literal
quotes + commas. The `fragments-ai` transforms see a string starting
with `"` and emit it verbatim, producing:

```yaml
# .claude/rules/ai-clis.md
paths: "modules/copilot-cli/**,modules/kiro-cli/**,packages/ai-clis/**"
```

Claude interprets this as a SINGLE literal glob pattern matching files
whose paths contain literal commas. No real files match. The rule
either never loads or loads unconditionally (ambiguous behavior,
Claude's actual handling untested).

**Fix:** change `packagePaths` to Nix lists:

```nix
packagePaths = {
  ai-clis = [
    "modules/copilot-cli/**"
    "modules/kiro-cli/**"
    "packages/ai-clis/**"
  ];
  mcp-servers = [
    "modules/mcp-servers/**"
    "packages/mcp-servers/**"
  ];
  monorepo = null;
  stacked-workflows = ["packages/stacked-workflows/**"];
};
```

With lists, the Claude transform emits correct YAML list form
(already handles `builtins.isList pathsAttr` → list output). Copilot
transform joins with commas (its native syntax). Kiro transform
needs a second fix (below).

### Bug 2: Kiro transform flattens lists to comma-joined strings

Current `packages/fragments-ai/default.nix` Kiro transform:

```nix
patternStr =
  if pathsAttr == null then null
  else if builtins.isList pathsAttr
  then ''"${lib.concatStringsSep "," pathsAttr}"''  # ← wrong
  else pathsAttr;
```

Kiro docs indicate multi-pattern supports arrays. The transform should
emit a YAML list when given a list input, not a comma-joined string.

**Fix:** emit YAML array syntax for multi-pattern fileMatchPattern:

```nix
patternStr =
  if pathsAttr == null then null
  else if builtins.isList pathsAttr
  then "[" + lib.concatMapStringsSep ", " (p: ''"${p}"'') pathsAttr + "]"
  else pathsAttr;
```

**Verification step (Checkpoint 4):** actually check Kiro docs for the
canonical multi-pattern syntax. If Kiro accepts comma-joined strings,
the current behavior is technically OK and we can defer the fix. If
Kiro requires arrays, fix before adding new fragments. Either way,
run `devenv tasks run generate:instructions` after the Claude fix
and diff the output against what the docs say each ecosystem wants.

### Bug 3: fragments-docs does not consume dev fragments

Verified by reading `packages/fragments-docs/default.nix`. The doc
site generators only produce:

- Snippets (nix-evaluated tables embedded via `{{#include}}`)
- Full pages from `pages/*.md` (authored prose, not fragments)
- Dynamic pages from nix data (overlayPackages, mcpServers)

There is NO generator that reads `dev/fragments/**/*.md` or a new
per-package dev fragment location. This is the gap for Checkpoint 7.

**Fix (Checkpoint 7, after fragments exist):** add a new generator
to `fragments-docs.passthru.generators` called `architectureFragments`
that reads a list of dev fragment paths, strips their YAML frontmatter,
and wraps them as mdbook pages. Registered into `docs/src/contributing/`
via `dev/generate.nix`. Single source of truth — same markdown body
feeds steering files AND mdbook.

---

## Design decisions (locked from Checkpoint 2 research)

### 1. Scope split

- **Always-loaded (monorepo category addition):** exactly ONE fragment.
  The `architecture-map` orientation doc. Target 120-150 lines.
- **Everything else path-scoped.** Each fragment has tight globs that
  match ONLY the files that fragment describes.
- No "always-load-in-case-it's-useful" fragments. The research is
  definitive: unused context degrades performance.

### 2. Granularity: <150 lines per fragment, hard budget

If a topic outgrows 150 lines, split by sub-concern into sibling
fragments with narrower scopes. Claude docs say <200 lines for
CLAUDE.md; we take the lower 150 target to leave headroom for the
<40% context utilization ceiling when multiple scoped fragments
co-load.

### 3. Content rule: non-inferable only

Every fragment must justify its tokens. Include:

- **Why** something is the way it is (design decisions, trade-offs)
- **Cross-cutting invariants** (config parity rules, cache-hit parity)
- **Pitfalls** (known bugs, subtle gotchas, migrations in flight)
- **Shapes of abstractions** spanning multiple files (fanout patterns,
  wrapper chains, activation lifecycles)
- **Debugging entry points** (what to grep, what to eval, what to check)

Exclude:

- Function signatures, file paths, line numbers (grep/Read finds them
  faster and they decay)
- Content already in code comments (DRY violation)
- Anything `/init` or an exploring agent could discover alone
- Ephemeral state (HITL progress, backlog items — those are `plan.md`
  and memory)

### 4. Self-maintenance: three layers

**Layer A — always-loaded directive.**

5-10 lines in the `architecture-map` fragment. Text:

> **Architecture fragment maintenance (MANDATORY):** This repo ships
> path-scoped architecture fragments in `packages/<pkg>/fragments/dev/`,
> `modules/<subdir>/fragments/dev/`, and `dev/fragments/monorepo/`.
> When you make changes that alter the shape of any abstraction a
> fragment describes, update the fragment in the SAME commit. Out-of-
> date fragments actively mislead future sessions and are worse than
> no fragment at all. If a fragment's `Last verified` marker predates
> your change to the area it scopes, review and update it.

**Layer B — per-fragment last-verified marker.**

Each scoped fragment opens with a short block:

```markdown
---
paths:
  - "modules/claude-code-buddy/**"
  - "packages/ai-clis/claude-code.nix"
---

> **Last verified:** 2026-04-07 (commit abc1234). If you touch the
> buddy activation flow or the claude-code wrapper chain and this
> fragment isn't updated in the same commit, stop and fix it.

# Buddy wrapper chain and activation

[body...]
```

**Layer C — future `/dev-update-fragments` skill (BACKLOG).**

Skill that on invocation:

1. Walks every fragment's `paths:` frontmatter
2. For each, finds matching files that changed since the fragment's
   `Last verified` commit (parsed from the marker)
3. Presents a diff review prompt per stale fragment
4. Updates last-verified markers after human approval

This is a backlog item — NOT implementing in this design. But the
FRAGMENT STRUCTURE enables it without the skill existing yet. The
`paths:` frontmatter already gives the skill the data it needs.

### 5. DRY across all outputs

Single markdown source feeds:

- `.claude/rules/<cat>.md` (path-scoped via `paths:`)
- `.github/instructions/<cat>.instructions.md` (via `applyTo:`)
- `.kiro/steering/<cat>.md` (via `inclusion: fileMatch`)
- `AGENTS.md` (concatenated flat for Codex and agents.md-compatible
  tools)
- `docs/src/contributing/<cat>.md` (mdbook architecture section —
  requires Checkpoint 7 fragments-docs extension)

Frontmatter stripped or transformed per output. Body is identical.

---

## Dumping-ground policy: co-location for NEW fragments

Existing fragments in `dev/fragments/{ai-clis,mcp-servers,stacked-workflows}/`
stay put. **Not migrating.** New fragments go where their subject code
lives:

```
packages/ai-clis/
  claude-code.nix
  any-buddy.nix
  fragments/
    dev/
      claude-code-wrapper.md      # scoped to claude-code.nix + buddy module
      activation-lifecycle.md     # NEW
    published/                    # reserved for future consumer-facing
                                  # fragments; empty initially
modules/ai/
  default.nix
  fragments/
    dev/
      fanout-semantics.md
modules/claude-code-buddy/
  default.nix
  fragments/
    dev/
      (could live here or with packages/ai-clis; see decision below)
dev/
  fragments/
    monorepo/
      architecture-map.md          # NEW, the only always-loaded addition
      ...existing fragments stay...
```

**Cross-cutting / non-package-scoped fragments stay in `dev/fragments/`.**
The `monorepo` category is legitimate because the content is repo-wide.
That's not dumping-ground — it's "orientation has one home."

**Which directory owns cross-module fragments?** When a fragment spans
multiple directories (e.g., claude-code wrapper chain lives half in
`packages/ai-clis/claude-code.nix` and half in
`modules/claude-code-buddy/default.nix`), place it where the
load-bearing entry point lives. For the wrapper chain, that's
`packages/ai-clis/` because the wrapper IS defined in claude-code.nix
and the activation script is downstream of that. The `paths:`
frontmatter includes BOTH directories.

### Generator extension to support co-located fragments

`dev/generate.nix` currently has:

```nix
mkDevFragment = pkg: name:
  fragments.mkFragment {
    text = builtins.readFile ./fragments/${pkg}/${name}.md;
    description = "dev/${pkg}/${name}";
    priority = 5;
  };
```

Extend to also read from co-located locations:

```nix
mkDevFragment = {location, pkg, name}:
  fragments.mkFragment {
    text = builtins.readFile (locationPath location pkg name);
    description = "${location}/${pkg}/${name}";
    priority = 5;
  };

locationPath = location: pkg: name:
  if location == "dev"
  then ./fragments/${pkg}/${name}.md
  else if location == "package"
  then ../packages/${pkg}/fragments/dev/${name}.md
  else if location == "module"
  then ../modules/${pkg}/fragments/dev/${name}.md
  else throw "unknown fragment location: ${location}";
```

And register fragments with their location in `devFragmentNames`:

```nix
devFragmentNames = {
  monorepo = [
    {location = "dev"; name = "architecture-map";}
    {location = "dev"; name = "build-commands";}
    ...
  ];
  ai-clis = [
    {location = "dev"; name = "packaging-guide";}      # existing
    {location = "package"; name = "claude-code-wrapper";}  # NEW
    {location = "package"; name = "activation-lifecycle";}  # NEW
  ];
  ...
};
```

Backward compatibility: the bare-string form
`devFragmentNames.<pkg> = ["name"]` implies `location = "dev"`, so
existing fragments don't need migration.

---

## Proposed fragment set (Checkpoint 4 + later)

All fragment names are provisional — `mkDevFragment` names them by
category + name, final filenames follow.

### Checkpoint 4: Write-from-memory fragments

Content I can write from this session's debugging experience without
further research. Each <150 lines.

| Fragment               | Category  | Location                                                       | Scope globs                                                        | Content                                                                                                                                                                                                                                      |
| ---------------------- | --------- | -------------------------------------------------------------- | ------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `architecture-map`     | monorepo  | `dev/fragments/monorepo/`                                      | (always loaded — no `paths:`)                                      | Repo layout, composition model, fragment pipeline 30k-foot view, skill routing reminder, **self-maintenance directive (Layer A)**                                                                                                            |
| `claude-code-wrapper`  | ai-clis   | `packages/ai-clis/fragments/dev/`                              | `packages/ai-clis/claude-code.nix`, `modules/claude-code-buddy/**` | Double-wrap chain (HM plugin → Bun wrapper → cli.js), `baseClaudeCode` passthru, why Bun runtime (wyhash alignment), state dir layout, fingerprint semantics                                                                                 |
| `buddy-activation`     | ai-clis   | `packages/ai-clis/fragments/dev/`                              | `modules/claude-code-buddy/**`, `packages/ai-clis/any-buddy.nix`   | Activation script lifecycle, fingerprint inputs, salt search worker, cli.js patching, companion field reset, common failure modes (null coercion, missing sops file, state dir corruption)                                                   |
| `ai-module-fanout`     | ai-module | `modules/ai/fragments/dev/`                                    | `modules/ai/**`                                                    | The per-CLI-enable-as-sole-gate decision, how each `ai.{claude,copilot,kiro}.enable` both fans out AND flips `programs.*.enable`, the cross-ecosystem data flow (skills/instructions/lspServers/settings), the dropped `ai.enable` rationale |
| `overlay-cache-parity` | overlays  | `packages/ai-clis/fragments/dev/` (or new `overlays` category) | `packages/**.nix` (excluding `fragments/**`)                       | Cache-hit parity rule: overlays must instantiate `ourPkgs` from `inputs.nixpkgs`, why, trade-off (double nixpkgs closure), verification protocol, points at the open backlog item                                                            |

### Checkpoint 5: Research-required fragments

Need actual code reading before writing. Research via Explore agents.

| Fragment                | Category      | Location                                                 | Scope globs                                                                                       | Research needed                                                                                                                                 |
| ----------------------- | ------------- | -------------------------------------------------------- | ------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `fragment-pipeline`     | lib-fragments | `lib/fragments.nix` sibling or `dev/fragments/monorepo/` | `lib/fragments.nix`, `dev/generate.nix`, `packages/fragments-ai/**`, `packages/fragments-docs/**` | How composition works, per-ecosystem transforms, frontmatter emission, the pipeline from dev fragments → CLAUDE.md / rules files / mdbook pages |
| `hm-module-conventions` | hm-modules    | `modules/fragments/dev/` or co-located per module        | `modules/**`                                                                                      | Assertion patterns, `mkIf` gating rules, config parity rules, how options relate to `programs.*`, when to use `mkDefault` vs `mkForce`          |

### Checkpoint 6: Overlay contract + other deep-dives (deferred)

Additional fragments as gaps become clear during implementation. Keep
the total small. Resist the urge to document everything.

---

## Per-ecosystem fanout verification (Checkpoint 4 deliverable)

After the prerequisite bug fixes land, run:

```bash
devenv tasks run generate:instructions
```

Then verify each output form per ecosystem:

**Claude (`.claude/rules/<cat>.md`):** frontmatter should be YAML
list, not a single string:

```yaml
---
description: ...
paths:
  - "glob/1/**"
  - "glob/2/**"
---
```

**Copilot (`.github/instructions/<cat>.instructions.md`):**
frontmatter should be comma-joined (native):

```yaml
---
applyTo: "glob/1/**,glob/2/**"
---
```

**Kiro (`.kiro/steering/<cat>.md`):** frontmatter should be YAML array
for multi-pattern, single string for single-pattern:

```yaml
---
description: ...
fileMatchPattern: ["glob/1/**", "glob/2/**"]
inclusion: fileMatch
name: <cat>
---
```

**AGENTS.md:** just the concatenated body, no scoping frontmatter.

Visual inspection of each file post-generation. If any output is
wrong, debug the transform before proceeding.

---

## Checkpoint plan (final)

| #   | Deliverable                                                                                                                                                                                                                                                        | Risk                                                          |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------- |
| 1   | Plan ack (user approval)                                                                                                                                                                                                                                           | —                                                             |
| 2   | Research doc: `dev/notes/steering-research.md`                                                                                                                                                                                                                     | Read-only (DONE, committed a012a41)                           |
| 3   | This spec (`docs/superpowers/specs/2026-04-07-steering-fragments-design.md`)                                                                                                                                                                                       | Read-only                                                     |
| 4a  | **Prerequisite fix**: `dev/generate.nix` `packagePaths` → list form; Kiro transform list handling fix (verify vs docs first); regenerate instruction files and commit                                                                                              | Additive (existing fragments switch to correctly-scoped form) |
| 4b  | **Generator extension**: `mkDevFragment` location discriminator; backward-compat bare-string form; no behavior change for existing fragments                                                                                                                       | Additive                                                      |
| 4c  | **Write-from-memory fragments**: `architecture-map`, `claude-code-wrapper`, `buddy-activation`, `ai-module-fanout`, `overlay-cache-parity`. Place in co-located dirs. Register in `devFragmentNames`. Regenerate. Verify output. Commit.                           | Additive                                                      |
| 5   | **Research-first fragments** via parallel Explore agents: `fragment-pipeline`, `hm-module-conventions`. Draft, review, commit.                                                                                                                                     | Additive                                                      |
| 6   | **Additional deep-dives** as gaps surface during implementation. Resist scope creep.                                                                                                                                                                               | Additive                                                      |
| 7   | **Docsite integration**: extend `fragments-docs.passthru.generators` to consume dev fragments as `architectureFragments`, wire into `dev/generate.nix`, add `docs/src/contributing/` mdbook section. Verify DRY — same markdown body in steering files AND mdbook. | Additive                                                      |
| 8   | **`repo-review` skill** run with fragments in place to catch any drift, gaps, or duplication.                                                                                                                                                                      | Read-only                                                     |

Each checkpoint commits independently. Tree stays buildable, flake
check stays green throughout.

---

## Open questions (to be resolved during implementation)

1. **Kiro multi-pattern syntax.** Verify whether Kiro's
   `fileMatchPattern` accepts comma-joined strings or requires YAML
   arrays. Current transform emits comma-joined; may or may not be
   correct. Check Kiro docs at Checkpoint 4 before the Kiro transform
   fix.

2. **Claude `paths:` for single-pattern fragments.** When a fragment
   has only one glob (e.g., `stacked-workflows` → `packages/stacked-workflows/**`),
   does the Claude transform emit list form with one entry, or bare
   string? Verify both work in Claude; the docs show list form
   consistently so default to list.

3. **Cross-cutting fragments directory conventions.** If a fragment
   scopes to `modules/**` (all HM modules), where does it live?
   Options: `modules/fragments/dev/` (new top-level), or
   `dev/fragments/hm-modules/` (existing dev category). Decision at
   Checkpoint 5 when writing `hm-module-conventions`.

4. **Kiro steering name key.** The Kiro transform takes `{name}` and
   emits `name: <category>` in frontmatter. With co-located fragments,
   the category name changes per location (e.g., `claude-code-wrapper`
   fragment lives under "ai-clis" category but describes
   "claude-code-buddy" — what should Kiro's `name:` field be?).
   Defer to Checkpoint 4 when the generator extension is being
   written.

---

## Out of scope

- Migrating existing `dev/fragments/ai-clis/`,
  `dev/fragments/mcp-servers/`, `dev/fragments/stacked-workflows/`
  to co-located dirs. Separate follow-up if ever.
- Adding a `/dev-update-fragments` skill. Backlog.
- Changing the existing `packages/coding-standards/fragments/`
  published-fragment pattern. Those ship to consumers and are working.
- Adding fragments for packages not touched in this session
  (mcp-servers overlays, stacked-workflows internals, etc.). If
  someone needs them, add them when they do.
- Changes to how CLAUDE.md, AGENTS.md, or the always-loaded files
  themselves are generated. Only ADDING a fragment to the monorepo
  category, not restructuring the existing pipeline.
