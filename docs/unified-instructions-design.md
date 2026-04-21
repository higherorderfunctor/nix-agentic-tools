# Unified Instructions Surface — Research & Design

> **Status:** context + rules shipped across Claude / Kiro / Copilot
> (HM + devenv). Codex factory + size guard deferred. Research
> captured 2026-04-17; implementation commits 8f0c16b, 7dad0b8,
> 419010a (2026-04-21).
>
> **Goal:** add a unified `ai.<cli>.{context,rules}` surface to the factory
> that fans out personal/global instruction content to every enabled
> ecosystem, respecting each ecosystem's native conventions and degrading
> gracefully where features differ.

## Motivation

The factory currently exposes `ai.kiro.instructions` (list-shaped) as a
stub. Consumers still hand-roll steering via `mkOutOfStoreSymlink`. The
problem isn't Kiro-specific — Claude, Copilot, and Codex each have their
own filename conventions, directory layouts, and frontmatter dialects for
personal instructions. A unified surface lets a consumer write one config
and have it correctly emitted for every enabled ecosystem, without the
consumer having to know each vendor's idiosyncrasies.

## Generalized transformer pattern

This document describes the **instructions** instance of a broader
architectural pattern that applies to every cross-ecosystem concern in
the factory. Apply the same shape to:

- **Instructions** (`ai.context` + `ai.rules`) — this document.
- **MCP servers** (`ai.mcpServers` + `ai.<cli>.mcpServers`) — typed
  schema at `lib/ai/mcpServer/commonSchema.nix`; per-ecosystem
  `renderServer` translates typed shape → native on-disk form
  (Claude's `programs.claude-code.mcpServers`, Kiro's `mcp.json`,
  Copilot's `--additional-mcp-config` target, Codex TBD).
- **Skills** (`ai.skills` + `ai.<cli>.skills`) — SKILL.md progressive
  disclosure, mostly convergent across ecosystems; transformer still
  handles per-ecosystem disk paths.
- **Agents** (`ai.agents` + `ai.<cli>.agents`) — shapes differ per
  ecosystem; may only partially unify. Future work.
- **LSP servers** (`ai.lspServers` + `ai.<cli>.lspServers`).
- **Environment variables** (`ai.environmentVariables` +
  `ai.<cli>.environmentVariables`).
- **Permissions** (`ai.permissions` + `ai.<cli>.permissions`).
- **Hooks** — cross-ecosystem shape still being defined.

### Uniform architecture

For every cross-ecosystem concern, the factory uses the same shape:

1. **Typed option surface.** A single canonical schema, consumable at
   two tiers:
   - `ai.<concern>` — cross-ecosystem (fans to every enabled CLI).
   - `ai.<cli>.<concern>` — per-ecosystem additive. Per-CLI wins on
     collision. Use this for ecosystem-exclusive content or to override
     a cross-ecosystem default.
2. **Per-ecosystem transformer.** Lives in `lib/ai/transformers/<cli>.nix`.
   Consumes the typed shape and emits ecosystem-native output (file
   contents, frontmatter dialect, disk paths).
3. **Per-CLI factory wiring.** `mkClaude.nix`, `mkKiro.nix`, `mkCopilot.nix`,
   `mkCodex.nix` call their transformer on the merged
   top-level + per-CLI attrset and write the results to the native disk
   paths that ecosystem reads.

### Design invariants

- **No ecosystem-specific option shapes at the consumer surface.** Users
  write typed once; translation is the factory's job.
- **No throwaway intermediate passthrough wiring.** Don't build
  `ai.claude.<concern>` that just forwards to `programs.claude-code.<concern>`
  on the way to building the real transformer later — that's two
  migrations for consumers.
- **Graceful degradation is explicit.** When a feature doesn't translate
  cleanly (e.g. path-scoped instructions into Codex's flat AGENTS.md),
  the transformer degrades deterministically (prose prefix, concat order,
  etc.) rather than silently dropping. Each concern documents its own
  degradation rules.
- **Escape hatch via per-CLI option.** Anything that can't be expressed
  in the cross-ecosystem shape goes in `ai.<cli>.<concern>` with
  ecosystem-native extensions allowed.

### Why one pattern

Consumers want to express intent once. Ecosystems disagree on filenames,
directory layouts, frontmatter dialects, and capabilities. The
transformer layer is where that disagreement gets absorbed — and
absorbing it once uniformly is cheaper than doing it ad-hoc per
concern. Every concern the factory covers should graduate through this
pattern.

## Landscape research

Primary-source research across all four ecosystems, conducted 2026-04-17.

### Claude Code

Source: <https://code.claude.com/docs/en/memory.md>, <https://code.claude.com/docs/en/configuration.md>

- **Global always-on:** `~/.claude/CLAUDE.md` auto-loaded at session start.
- **Global directory:** `~/.claude/rules/*.md` auto-loaded. Files without
  `paths:` frontmatter load unconditionally; files with `paths:` load
  on-demand when Claude reads matching files.
- **Project:** `./CLAUDE.md`, `.claude/rules/*.md`, subdirectory
  `CLAUDE.md` (lazy, loaded when Claude reads that subtree).
- **Frontmatter:** `paths: [glob, …]` native. No other scoping fields.
- **Imports:** `@path/to/file.md` recursive, resolves relative to containing
  file, max depth 5, expanded inline at startup.
- **AGENTS.md:** **not read natively.** Workaround: `@AGENTS.md` inside
  `CLAUDE.md`.
- **Merge:** walks up from cwd; all discovered files concatenated. Local
  scope (`CLAUDE.local.md`) appends last and wins conflicts.

### Kiro (CLI 2.x)

Sources: <https://kiro.dev/docs/steering/>, <https://kiro.dev/docs/cli/steering/>, <https://kiro.dev/docs/cli/skills/>, <https://kiro.dev/blog/stop-repeating-yourself/>

- **Global always-on:** `~/.kiro/steering/**/*.md` — **directory-native**,
  no single-file convention.
- **Also reads:** `~/.kiro/steering/AGENTS.md` natively (per blog post).
- **Project:** `.kiro/steering/**/*.md`. CLI's default agent loads the
  glob; custom agents must opt in via `resources`.
- **Frontmatter:** `inclusion: always | fileMatch | manual`;
  `fileMatchPattern:` (string or list of globs); `name:`/`description:`
  optional.
- **Manual mode:** `inclusion: manual` — loaded only on `#name` reference
  in chat or via slash-command selection.
- **AGENTS.md:** natively supported at workspace root AND
  `~/.kiro/steering/`.
- **Merge:** global + workspace additive; workspace wins on conflict.
- **Skills:** `~/.kiro/skills/`, progressive disclosure, Claude skills
  compatible.

### Copilot CLI (terminal agent — distinct from VS Code extension)

Sources: <https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-custom-instructions>, <https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/create-custom-agents-for-cli>, <https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-skills>

- **Config root:** `~/.copilot/` (overridable via `COPILOT_HOME`). Note:
  `~/.config/github-copilot/` belongs to the `gh-copilot` gh-extension,
  **not** the CLI.
- **Global always-on:** `~/.copilot/copilot-instructions.md` (single
  file). **No global multi-file directory.**
- **Project always-on:** `.github/copilot-instructions.md`, `AGENTS.md`
  (primary), `CLAUDE.md`, `GEMINI.md` — all read natively by the CLI.
- **Project directory:** `.github/instructions/**/*.instructions.md`
  recursive, with `applyTo: glob,glob` frontmatter.
- **Env var:** `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` for extra AGENTS.md
  dirs.
- **Frontmatter:** `applyTo:` is CLI-native (not VS-Code-only).
- **Merge:** root AGENTS.md = "primary"; everything else = "additional"
  (additive).
- **Skills:** scans `~/.copilot/skills/`, `~/.claude/skills/`,
  `~/.agents/skills/`.

### Codex CLI (OpenAI 2025 agentic terminal, not the legacy model)

Sources: <https://developers.openai.com/codex/guides/agents-md>, <https://developers.openai.com/codex/skills>

- **Global always-on:** `$CODEX_HOME/AGENTS.md` (default `~/.codex/`).
  `AGENTS.override.md` wins if present. Only the first non-empty file
  loads — **no directory support**.
- **Config:** `~/.codex/config.toml` with `project_doc_fallback_filenames`,
  `project_doc_max_bytes` (default **32 KiB**), `[features] child_agents_md`.
- **Project:** Walks DOWN from project root to cwd. One AGENTS.md per
  directory level, additively concatenated. Does not descend into
  siblings or below cwd.
- **CLAUDE.md:** not read by default; user can add it to
  `project_doc_fallback_filenames`.
- **Frontmatter:** **not supported** for AGENTS.md. Path scoping achieved
  solely through directory placement of nested AGENTS.md files.
- **Imports:** `@file` works in interactive prompts only — **not** as an
  include inside AGENTS.md. ([openai/codex#17401](https://github.com/openai/codex/issues/17401))
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
| Inclusion modes             | always / path-scoped   | always / fileMatch / manual                 | always / applyTo                                                            | always only               |
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
   semantics, different field names and list-vs-string encoding — plus
   Codex, which has no frontmatter at all.
3. **Manual/on-demand.** Only Kiro has it on instructions
   (`inclusion: manual`). Others push this to the **Skills** surface (a
   separate, convergent standard — SKILL.md progressive disclosure).
4. **Imports.** Only Claude has a composable include syntax.
5. **AGENTS.md convergence is real.** Kiro, Copilot, Codex read it
   natively. Claude is the outlier.

## Proposed surface

Symmetric top-level and per-ecosystem shape:

```nix
# Top-level (fans to every enabled ecosystem)
ai.context     = str | path;                         # optional
ai.rules.<name> = { text; paths?; description?; };   # optional

# Per-ecosystem (additive; wins on name collision)
ai.<cli>.context     = str | path;                   # optional
ai.<cli>.rules.<name> = { text; paths?; description?; };
```

**Type of each rule entry:**

```nix
rules.<name> = lib.types.submodule {
  options = {
    text = lib.mkOption {
      type = lib.types.either lib.types.str lib.types.path;
      description = "Inline content or path to a .md file.";
    };
    paths = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      description = "Globs this rule applies to. null = always-on.";
    };
    description = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Short description (used by Kiro frontmatter).";
    };
    skipIfUnsupported = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        If true, silently drop this rule when fanning to ecosystems that
        don't support path scoping natively. Default false = eval error.
      '';
    };
  };
};
```

**Effective value per ecosystem** = top-level `context`/`rules` merged
with `ai.<cli>.context`/`ai.<cli>.rules`. Name collisions: per-CLI wins.

### Kiro context filename override

Kiro has no dominant single-file convention globally. The factory
defaults to AGENTS.md (Kiro reads it natively from
`~/.kiro/steering/`) but allows override:

```nix
ai.kiro.contextFilename = lib.mkOption {
  type = lib.types.str;
  default = "AGENTS.md";
  description = "Filename for ai.kiro.context inside ~/.kiro/steering/.";
};
```

## Fanout semantics per ecosystem

|             | `context` →                                              | `rules.<name>` →                                                                 |
| ----------- | -------------------------------------------------------- | -------------------------------------------------------------------------------- |
| **Claude**  | `~/.claude/CLAUDE.md`                                    | `~/.claude/rules/<name>.md` with `paths:` frontmatter if set                     |
| **Kiro**    | `~/.kiro/steering/<contextFilename>` (default AGENTS.md) | `~/.kiro/steering/<name>.md` with `inclusion:` + `fileMatchPattern:` frontmatter |
| **Copilot** | `~/.copilot/copilot-instructions.md`                     | **concat** into `copilot-instructions.md` after `context` (no global dir)        |
| **Codex**   | `~/.codex/AGENTS.md`                                     | **concat** into `AGENTS.md` after `context` (no dir, no scoping)                 |

### Concat format (Copilot-global, Codex)

Rules ordered alphabetically by attribute name (aligns with numeric-prefix
conventions like `00-`, `01-`, …). Each chunk prefixed with an HTML
comment marker for traceability:

```markdown
<!-- rule: ip-protection -->
<content of ip-protection rule>

<!-- rule: tool-usage -->
<content of tool-usage rule>
```

**No synthesized H1** — existing content typically has its own H1, and
double-heading degrades readability. HTML comments are searchable,
model-visible, and non-mangling.

### Path-scope degradation (non-native ecosystems)

When a rule has `paths != null` and fans to Codex or Copilot-global
(neither supports path scoping), **bake the scope into the prose**:

```markdown
<!-- rule: git-ops -->

_Apply this guidance only when working with files matching: `**/.git/**`_

<original rule content>
```

Multi-glob: `` `src/**`, `lib/**` `` joined with commas.

This degrades gracefully — native ecosystems emit real frontmatter,
non-native ones get readable prose the model will follow. Content
isn't silently dropped; intent is preserved.

**Opt-out:** `skipIfUnsupported = true` — rule is omitted from
non-scoping ecosystems entirely. Default is to include-with-prose so
bugs don't ship silently.

## Codex size guard

- At eval time, compute `sizeOf(context) + sizeOf(concat(rules))` for
  Codex's effective output.
- Compare against `ai.codex.settings."project_doc_max_bytes"` (or the
  32 KiB default if unset).
- If over cap: **hard eval error** listing the rules that pushed it
  over and suggesting either trimming or raising the cap.
- Rationale: Codex silently truncates overflow. An eval error is the
  only way to surface the problem before a surprise in production.

## Implementation status

1. **Transformers** — claude, copilot, kiro, agentsmd already shipped in
   `lib/ai/transformers/` before this work; reused as-is. Codex maps to
   `agentsmd` (flat body, no frontmatter) when `mkCodex` lands.
2. **Factory HM + devenv transform** — `context` + `rules` top-level and
   per-CLI options added; merge + pass-through landed.
   **Shipped:** commits 8f0c16b, 7dad0b8.
3. **Per-CLI factories.**
   - **Claude:** context delegates to `programs.claude-code.context`;
     rules emit to `.claude/rules/<name>.md` via `claudeTransformer`.
     Shipped 8f0c16b, 7dad0b8.
   - **Kiro:** context → `<configDir>/steering/<contextFilename>`
     (AGENTS.md default); rules → `<configDir>/steering/<name>.md` via
     `kiroTransformer`. Shipped 8f0c16b, 7dad0b8.
   - **Copilot:** context → `<configDir>/<contextFilename>`
     (copilot-instructions.md default); rules →
     `.github/instructions/<name>.instructions.md` via
     `copilotTransformer`. Shipped 7dad0b8, 419010a.
   - **Codex:** `mkCodex` factory not yet landed (deferred with Codex
     ecosystem work — see plan.md "Add OpenAI Codex").
4. **Codex size guard** — eval-time assertion. **Deferred** with (3)
   Codex.
5. **Consumer migration (`nixos-config`)** — out of scope for this repo.
   Consumer can now use `ai.kiro.rules = builtins.mapAttrs (…) (builtins.readDir …)`
   on their own steering directory.

### Not yet shipped

- **Path-scope prose degradation for Codex / Copilot-global concat** — the
  design specifies a prose prefix when a scoped rule fans to an
  ecosystem without native frontmatter. Not wired; today
  `ai.copilot.rules` emits to `.github/instructions/` (project-scope
  with native `applyTo:`), not a Copilot-global concat. Codex has no
  factory yet.
- **`skipIfUnsupported` rule option** — design called for eval-time
  error when a path-scoped rule targets an ecosystem without native
  path scoping, with opt-out. Not implemented; no target ecosystem
  currently requires it (Claude / Kiro / Copilot-project all support
  native path scoping).
- **Deprecation of legacy `ai.instructions` list-shape** — `instructions`
  and `rules` coexist today. Deprecation warning and migration guide not
  yet added.

## Scope & non-goals (intentionally deferred)

This design covers **personal/global instruction files only**. Out of
scope for this pass, to be revisited:

- **Skills** — separate surface with distinct load semantics
  (progressive disclosure, agent-initiated). Convergent across ecosystems
  (`~/.claude/skills/`, `~/.agents/skills/`, `~/.kiro/skills/`,
  `~/.copilot/skills/`) but deserves its own design pass. Keep
  `ai.<cli>.skills` separate from instructions.
- **Custom agents** — Claude subagents (`~/.claude/agents/`), Kiro custom
  agents (JSON configs + resources), Copilot custom agents (`.agent.md`).
  Different shapes per ecosystem; may not be unifiable. Future design
  pass.
- **Project-scope instructions** — this design targets HM/global. Project
  scope (`./CLAUDE.md`, `.kiro/steering/`, `.github/instructions/`, etc.)
  would use the same option names but route through the devenv module
  writing to the workspace instead of `~/`. Same shape, different output
  target — should be straightforward once the HM path lands.
- **Claude `CLAUDE.local.md`** — gitignored append-after-CLAUDE.md file.
  Could map to something like `ai.claude.localContext` but niche.
- **Codex `AGENTS.override.md`** — wins over AGENTS.md. Same story as
  local — could expose via `ai.codex.overrideContext` if ever needed.
- **Codex hierarchical project AGENTS.md** (walk-down from root to cwd,
  one per directory) — distinct from the dir-of-files model and needs
  its own treatment if we want to surface it.
- **Cross-ecosystem shared reads** — Copilot CLI reads CLAUDE.md and
  GEMINI.md; Kiro reads AGENTS.md. The factory could exploit this
  (e.g. emit AGENTS.md once and skip per-ecosystem duplication) but
  that's a later optimization — explicit per-ecosystem emit is more
  predictable.
- **Hooks** — not an instruction surface; tracked separately (already
  partially exposed via `programs.claude-code.hooks`).
- **MCP resources and prompts** — orthogonal to instruction files,
  tracked separately.

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
