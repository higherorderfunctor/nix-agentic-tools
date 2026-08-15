# Unified Instructions Surface — Research, Design & Status

> **Status:** typed context ships across Claude / Codex / Copilot / Kimchi /
> Kiro with Home Manager and devenv option parity; Copilot Home Manager is a
> deliberate no-op. Keyed rules ship for Claude / Codex / Copilot / Kiro; Kimchi
> has no rules pool. Codex lowers flat AGENTS.md content with explicit scope
> degradation and a byte-size guard. Research captured 2026-04-17; original
> implementation commits 8f0c16b, 7dad0b8, 419010a (2026-04-21); Codex
> implementation landed in PRs #657, #658, and #668 (2026-08-01). The
> typed-content/keyed-rule redesign landed in 2026-08: the list-shaped
> `instructions` surface is retired rather than aliased.
>
> **Goal:** provide a unified `ai.<cli>.{context,rules}` surface that fans out
> personal/global guidance to every capable enabled ecosystem, respecting each
> ecosystem's native conventions and documenting deliberate exclusions.

## Motivation

The original factory exposed `ai.kiro.instructions` (list-shaped) as a stub, and
consumers hand-rolled steering via `mkOutOfStoreSymlink`. The problem wasn't
Kiro-specific — Claude, Copilot, and Codex each have their own filename
conventions, directory layouts, and frontmatter dialects for personal
instructions. A unified surface lets a consumer write one config and have it
correctly emitted for every enabled ecosystem, without the consumer having to
know each vendor's idiosyncrasies.

## Generalized transformer pattern

This document describes the **context and rules** instance of a broader
architectural pattern that applies to every cross-ecosystem concern in the
factory. Apply the same shape to:

- **Guidance** (`ai.context` + `ai.rules`) — this document.
- **MCP servers** (`ai.mcpServers` + `ai.<cli>.mcpServers`) — typed schema at
  `lib/ai/mcpServer/commonSchema.nix`; per-ecosystem `renderServer` translates
  typed shape → native on-disk form (Claude's `programs.claude-code.mcpServers`,
  Kiro's `mcp.json`, Copilot's `--additional-mcp-config` target, Codex's native
  `[mcp_servers.<name>]` TOML tables).
- **Skills** (`ai.skills` + `ai.<cli>.skills`) — SKILL.md progressive
  disclosure, mostly convergent across ecosystems; transformer still handles
  per-ecosystem disk paths.
- **Agents** (`ai.agents` + `ai.<cli>.agents`) — shapes differ per ecosystem;
  may only partially unify. Future work.
- **LSP servers** (`ai.lspServers` + `ai.<cli>.lspServers`).
- **Environment variables** (`ai.environmentVariables` +
  `ai.<cli>.environmentVariables`).
- **Permissions** (`ai.permissions` + `ai.<cli>.permissions`).
- **Hooks** — cross-ecosystem shape still being defined.

### Uniform architecture

For every cross-ecosystem concern, the factory uses the same shape:

1. **Typed option surface.** A single canonical schema, consumable at two tiers:
   - `ai.<concern>` — cross-ecosystem (fans to every enabled CLI).
   - `ai.<cli>.<concern>` — per-ecosystem layer. Use this for
     ecosystem-exclusive content or to override a scalar cross-ecosystem
     default. Named attrset pools are additive only for distinct names;
     shared/per-CLI duplicates fail the collision check instead of choosing a
     winner. Lists concatenate in their documented order.
2. **Per-ecosystem transformer.** Lives in `lib/ai/transformers/<cli>.nix`.
   Consumes the typed shape and emits ecosystem-native output (file contents,
   frontmatter dialect, disk paths).
3. **Per-CLI factory wiring.** `mkClaude.nix`, `mkKiro.nix`, `mkCopilot.nix`,
   `mkCodex.nix` call their transformer on the merged top-level + per-CLI
   attrset and write the results to the native disk paths that ecosystem reads.

### Design invariants

- **No ecosystem-specific option shapes at the consumer surface.** Users write
  typed once; translation is the factory's job.
- **No throwaway intermediate passthrough wiring.** Don't build
  `ai.claude.<concern>` that just forwards to `programs.claude-code.<concern>`
  on the way to building the real transformer later — that's two migrations for
  consumers.
- **Graceful degradation is explicit.** When a feature doesn't translate cleanly
  (e.g. path-scoped instructions into Codex's flat AGENTS.md), the transformer
  degrades deterministically (prose prefix, concat order, etc.) rather than
  silently dropping. Each concern documents its own degradation rules.
- **Escape hatch via per-CLI option.** Anything that can't be expressed in the
  cross-ecosystem shape goes in `ai.<cli>.<concern>` with ecosystem-native
  extensions allowed.

### Why one pattern

Consumers want to express intent once. Ecosystems disagree on filenames,
directory layouts, frontmatter dialects, and capabilities. The transformer layer
is where that disagreement gets absorbed — and absorbing it once uniformly is
cheaper than doing it ad-hoc per concern. Every concern the factory covers
should graduate through this pattern.

## Landscape research

Primary-source research across all four ecosystems, conducted 2026-04-17.

### Claude Code

Source: <https://code.claude.com/docs/en/memory.md>,
<https://code.claude.com/docs/en/configuration.md>

- **Global always-on:** `~/.claude/CLAUDE.md` auto-loaded at session start.
- **Global directory:** `~/.claude/rules/*.md` auto-loaded. Files without
  `paths:` frontmatter load unconditionally; files with `paths:` load on-demand
  when Claude reads matching files.
- **Project:** `./CLAUDE.md`, `.claude/rules/*.md`, subdirectory `CLAUDE.md`
  (lazy, loaded when Claude reads that subtree).
- **Frontmatter:** `paths: [glob, …]` native. No other scoping fields.
- **Imports:** `@path/to/file.md` recursive, resolves relative to containing
  file, max depth 5, expanded inline at startup.
- **AGENTS.md:** **not read natively.** Workaround: `@AGENTS.md` inside
  `CLAUDE.md`.
- **Merge:** walks up from cwd; all discovered files concatenated. Local scope
  (`CLAUDE.local.md`) appends last and wins conflicts.

### Kiro (CLI 2.x)

Sources: <https://kiro.dev/docs/steering/>,
<https://kiro.dev/docs/cli/steering/>, <https://kiro.dev/docs/cli/skills/>,
<https://kiro.dev/blog/stop-repeating-yourself/>

- **Global always-on:** `~/.kiro/steering/**/*.md` — **directory-native**, no
  single-file convention.
- **Also reads:** `~/.kiro/steering/AGENTS.md` natively (per blog post).
- **Project:** `.kiro/steering/**/*.md`. CLI's default agent loads the glob;
  custom agents must opt in via `resources`.
- **Frontmatter:** `inclusion: always | auto | fileMatch | manual`;
  `fileMatchPattern:` (string or list of globs). `auto` requires `name:` and
  `description:`; those fields are optional for the other modes.
- **Manual mode:** `inclusion: manual` — loaded only on `#name` reference in
  chat or via slash-command selection.
- **AGENTS.md:** natively supported at workspace root AND `~/.kiro/steering/`.
- **Merge:** global + workspace additive; workspace wins on conflict.
- **Skills:** `~/.kiro/skills/`, progressive disclosure, Claude skills
  compatible.

### Copilot CLI (terminal agent — distinct from VS Code extension)

Sources:
<https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-custom-instructions>,
<https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/create-custom-agents-for-cli>,
<https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-skills>

- **Config root:** `~/.copilot/` (overridable via `COPILOT_HOME`). Note:
  `~/.config/github-copilot/` belongs to the `gh-copilot` gh-extension, **not**
  the CLI.
- **Global always-on:** `~/.copilot/copilot-instructions.md` (single file). **No
  global multi-file directory.**
- **Project always-on:** `.github/copilot-instructions.md`, `AGENTS.md`
  (primary), `CLAUDE.md`, `GEMINI.md` — all read natively by the CLI.
- **Project directory:** `.github/instructions/**/*.instructions.md` recursive,
  with `applyTo: glob,glob` frontmatter.
- **Env var:** `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` for extra AGENTS.md dirs.
- **Frontmatter:** `applyTo:` is CLI-native (not VS-Code-only).
- **Merge:** root AGENTS.md = "primary"; everything else = "additional"
  (additive).
- **Skills:** scans `~/.copilot/skills/`, `~/.claude/skills/`,
  `~/.agents/skills/`.

### Codex CLI (OpenAI 2025 agentic terminal, not the legacy model)

Sources: <https://developers.openai.com/codex/guides/agents-md>,
<https://developers.openai.com/codex/skills>

- **Global always-on:** `$CODEX_HOME/AGENTS.md` (default `~/.codex/`).
  `AGENTS.override.md` wins if present. Only the first non-empty file loads —
  **no directory support**.
- **Config:** `~/.codex/config.toml` with `project_doc_fallback_filenames`,
  `project_doc_max_bytes` (default **32 KiB**), `[features] child_agents_md`.
- **Project:** Walks DOWN from project root to cwd. One AGENTS.md per directory
  level, additively concatenated. Does not descend into siblings or below cwd.
- **CLAUDE.md:** not read by default; user can add it to
  `project_doc_fallback_filenames`.
- **Frontmatter:** **not supported** for AGENTS.md. Path scoping achieved solely
  through directory placement of nested AGENTS.md files.
- **Imports:** `@file` works in interactive prompts only — **not** as an include
  inside AGENTS.md.
  ([openai/codex#17401](https://github.com/openai/codex/issues/17401))
- **Size cap:** 32 KiB default, overflow silently dropped.
- **Skills:** `~/.agents/skills/` (NOT under `~/.codex/`). Progressive
  disclosure. Claude skills compatible.

### Comparison matrix

| Axis                        | Claude                 | Kiro                                        | Copilot CLI                                                                 | Codex                     |
| --------------------------- | ---------------------- | ------------------------------------------- | --------------------------------------------------------------------------- | ------------------------- |
| Global always-on file       | `~/.claude/CLAUDE.md`  | —                                           | `~/.copilot/copilot-instructions.md`                                        | `~/.codex/AGENTS.md`      |
| Global multi-file dir       | `~/.claude/rules/*.md` | `~/.kiro/steering/**/*.md`                  | —                                                                           | —                         |
| Project always-on           | `./CLAUDE.md`          | `./AGENTS.md`                               | `.github/copilot-instructions.md` + `AGENTS.md` + `CLAUDE.md` + `GEMINI.md` | `./AGENTS.md` (walk-down) |
| Project multi-file dir      | `.claude/rules/*.md`   | `.kiro/steering/**/*.md`                    | `.github/instructions/**/*.instructions.md`                                 | —                         |
| Path-scope frontmatter      | `paths:`               | `inclusion:fileMatch` + `fileMatchPattern:` | `applyTo:`                                                                  | — (dir placement only)    |
| Inclusion modes             | always / path-scoped   | always / auto / fileMatch / manual          | always / applyTo                                                            | always only               |
| On-demand refs              | Skills                 | `#name` + Skills                            | Skills + `/skillname`                                                       | Skills                    |
| `@file` imports             | native, recursive      | —                                           | —                                                                           | —                         |
| Reads AGENTS.md natively    | **no**                 | yes                                         | yes (primary)                                                               | yes (primary)             |
| Reads cross-ecosystem files | n/a                    | no                                          | `CLAUDE.md` + `GEMINI.md`                                                   | — (unless in fallbacks)   |
| Size cap documented         | —                      | —                                           | —                                                                           | 32 KiB                    |

## Key divergences

1. **Single-file vs directory.** Kiro is directory-native (no single file).
   Codex is single-file-native (no directory). Claude and Copilot-project
   support both. Copilot-global and `~/.codex/` support only one file.
2. **Path-scoping dialect.** Three native frontmatter formats, equivalent
   semantics, different field names and list-vs-string encoding — plus Codex,
   which has no frontmatter at all.
3. **Semantic/manual loading.** Only Kiro has description-triggered
   `inclusion: auto` and on-demand `inclusion: manual` on instructions. Others
   push on-demand loading to the **Skills** surface (a separate, convergent
   standard — SKILL.md progressive disclosure).
4. **Imports.** Only Claude has a composable include syntax.
5. **AGENTS.md convergence is real.** Kiro, Copilot, Codex read it natively.
   Claude is the outlier.

## Proposed surface

Symmetric top-level and per-ecosystem shape:

```nix
# Top-level (fans to every enabled ecosystem)
ai.context = { text = "..."; }; # exactly one of text/source
ai.rules.<name> = { text = "..."; matcher = ["src/**"]; };

# Per-ecosystem (additive; wins on name collision)
ai.<cli>.context = { source = ./CONTEXT.md; filename = "AGENTS.md"; };
ai.<cli>.rules.<name> = { source = ./rule.md; matcher = null; };
```

**Type of each rule entry:**

```nix
rules.<name> = lib.types.submodule {
  options = {
    text = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = "Inline Markdown content; mutually exclusive with source.";
    };
    source = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Markdown file source; mutually exclusive with text.";
    };
    matcher = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      description = ''
        Globs this rule applies to. null = always-on; a scoped list must be
        non-empty.
      '';
    };
    description = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Short description (used by Kiro frontmatter).";
    };
  };
};
```

**Effective value per ecosystem:** root and per-runtime context concatenate
root-first into one runtime-named artifact. Top-level and per-CLI `rules` are
additive only for distinct names; duplicate names fail the shared collision
check.

### Kiro context filename override

Kiro has no dominant single-file convention globally. The factory defaults to
AGENTS.md (Kiro reads it natively from `~/.kiro/steering/`) but allows override:

```nix
ai.kiro.context.filename = "AGENTS.md";
```

## Fanout semantics per ecosystem

|             | `context` →                                                               | `rules.<name>` →                                                                 |
| ----------- | ------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| **Claude**  | `~/.claude/CLAUDE.md`                                                     | `~/.claude/rules/<name>.md` with `paths:` frontmatter when matched               |
| **Kiro**    | HM `~/.kiro/steering/AGENTS.md`; devenv repo-root `AGENTS.md`             | `~/.kiro/steering/<name>.md` with `inclusion:` + `fileMatchPattern:` frontmatter |
| **Copilot** | devenv `.github/copilot-instructions.md`; Home Manager deliberately no-op | devenv `.github/instructions/<name>.instructions.md`; Home Manager no-op         |
| **Codex**   | HM `~/.codex/AGENTS.md`; devenv repo-root `AGENTS.md`                     | **concat** into the same AGENTS.md after context                                 |

### Concat format (Codex and shared repo-root AGENTS.md)

Rules ordered alphabetically by attribute name (aligns with numeric-prefix
conventions like `00-`, `01-`, …). Each chunk prefixed with an HTML comment
marker for traceability:

```markdown
<!-- rule: ip-protection -->
<content of ip-protection rule>

<!-- rule: tool-usage -->
<content of tool-usage rule>
```

**No synthesized H1** — existing content typically has its own H1, and
double-heading degrades readability. HTML comments are searchable,
model-visible, and non-mangling.

### Matcher degradation (flat AGENTS.md ecosystems)

When a rule has `matcher != null` and fans to Codex, **bake the scope into the
prose**:

```markdown
<!-- rule: git-ops -->

_Apply this guidance only when working with files matching: `**/.git/**`_

<original rule content>
```

Multi-glob: `` `src/**`, `lib/**` `` joined with commas.

This degrades gracefully — native ecosystems emit real frontmatter, non-native
ones get readable prose the model will follow. Content isn't silently dropped;
intent is preserved.

The shared repo-root AGENTS.md admits only unscoped rule units. Kiro emits its
scoped rules separately with native `fileMatch` metadata.

## Codex size guard

- At eval time, compute `sizeOf(context) + sizeOf(concat(rules))` for Codex's
  effective output.
- Compare against `ai.codex.projectDocMaxBytes` (32 KiB by default).
- If over cap: **hard eval error** listing the rules that pushed it over and
  suggesting either trimming or raising the cap.
- Rationale: Codex silently truncates overflow. An eval error is the only way to
  surface the problem before a surprise in production.

The generated base filename remains `AGENTS.md`. Codex's native
`AGENTS.override.md` precedence can suppress that file, while configured
fallback filenames are consulted only when neither native filename exists. Those
are separate override/tree-placement and TOML discovery surfaces; this flat
writer does not duplicate fallback content or claim ownership of an existing
override file.

## Implementation status

1. **Transformers** — claude, copilot, kiro, agentsmd already shipped in
   `lib/ai/transformers/` before this work; reused as-is. Codex maps to
   `agentsmd` (flat body, no frontmatter).
2. **Factory HM + devenv transform** — `context` + `rules` top-level and per-CLI
   options added; merge + pass-through landed. **Shipped:** commits 8f0c16b,
   7dad0b8.
3. **Per-CLI factories.**
   - **Claude:** context delegates to `programs.claude-code.context`; rules emit
     to `.claude/rules/<name>.md` via `claudeTransformer`. Shipped 8f0c16b,
     7dad0b8.
   - **Kiro:** context → HM `<configDir>/steering/AGENTS.md` or devenv repo-root
     `AGENTS.md`; rules → `<configDir>/steering/<name>.md` via
     `kiroTransformer`.
   - **Copilot:** devenv context → `<projectDir>/<context.filename>` and rules →
     `<projectDir>/instructions/<name>.instructions.md` via
     `copilotTransformer`. Home Manager keeps the identical typed options for
     schema parity but deliberately emits neither surface.
   - **Codex:** shared/per-app context and rules lower into `~/.codex/AGENTS.md`
     for Home Manager and project-root `AGENTS.md` for devenv. Scoped content
     degrades to explicit prose.
4. **Codex size guard** — shipped as an eval-time byte assertion against
   `ai.codex.projectDocMaxBytes` (32 KiB by default), with rendered and
   per-contribution size diagnostics.
5. **Consumer migration (`nixos-config`)** — out of scope for this repo.
   Consumer can now use
   `ai.kiro.rules = builtins.mapAttrs (…) (builtins.readDir …)` on their own
   steering directory.

The legacy `ai.instructions` list shape is retired without an alias. Package
guidance now contributes named per-runtime rules at `mkDefault` priority.

## Original scope and adjacent-surface status

This design originally covered **personal/global instruction files only**.
Adjacent surfaces were kept separate so incompatible native formats were not
forced through Markdown. Their current disposition is:

- **Skills — shipped separately.** They retain distinct load semantics
  (progressive disclosure, agent-initiated) and converge across ecosystems
  (`~/.claude/skills/`, `~/.agents/skills/`, `~/.kiro/skills/`,
  `~/.copilot/skills/`). `ai.<cli>.skills` remains separate from instructions.
- **Custom agents — partially unified.** Portable semantic records fan out to
  Claude, Codex, and Copilot; Codex renders standalone TOML. Legacy Markdown
  remains Claude/Copilot-only, and Kiro's incompatible JSON agent model remains
  native-only.
- **Project-scope guidance — shipped through devenv.** The same option names
  route to project-native paths such as root `AGENTS.md`, `.kiro/steering/`, and
  `.github/instructions/` rather than Home Manager's user-global paths.
- **Claude `CLAUDE.local.md`** — gitignored append-after-CLAUDE.md file. Could
  map to something like `ai.claude.localContext` but niche.
- **Codex `AGENTS.override.md`** — wins over AGENTS.md. Same story as local —
  could expose via `ai.codex.overrideContext` if ever needed.
- **Codex fallback filenames** — configure discovery through the native
  `ai.codex.nativeSettings.project_doc_fallback_filenames` escape hatch; do not
  copy fallback content into generated AGENTS.md.
- **Codex hierarchical project AGENTS.md** (walk-down from root to cwd, one per
  directory) — distinct from the dir-of-files model and needs its own treatment
  if we want to surface it.
- **Cross-ecosystem shared reads** — Copilot CLI reads CLAUDE.md and GEMINI.md;
  Kiro reads AGENTS.md. The factory could exploit this (e.g. emit AGENTS.md once
  and skip per-ecosystem duplication) but that's a later optimization — explicit
  per-ecosystem emit is more predictable.
- **Hooks — shipped separately where semantics intersect.** Portable command
  groups span the exact Claude/Codex lifecycle intersection; runtime-native
  events and handler fields remain under `ai.<cli>.hooks`.
- **MCP resources and prompts** — orthogonal to instruction files, tracked
  separately.

## Sources

**Claude Code:**

- <https://code.claude.com/docs/en/memory.md>
- <https://code.claude.com/docs/en/configuration.md>
- <https://code.claude.com/docs/en/sub-agents.md>

**Kiro:**

- <https://kiro.dev/docs/steering/>
- <https://kiro.dev/docs/cli/steering/>
- <https://kiro.dev/docs/cli/skills/>
- <https://kiro.dev/docs/cli/custom-agents/configuration-reference/>
- <https://kiro.dev/blog/stop-repeating-yourself/>

**Copilot CLI:**

- <https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-custom-instructions>
- <https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/create-custom-agents-for-cli>
- <https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-skills>
- <https://docs.github.com/copilot/concepts/agents/about-copilot-cli>

**Codex CLI:**

- <https://developers.openai.com/codex/guides/agents-md>
- <https://developers.openai.com/codex/skills>
- <https://github.com/openai/codex/issues/4354> (global AGENTS.md auto-load)
- <https://github.com/openai/codex/issues/17401> (`@include` directive request)
