# Cross-ecosystem `ai.agents` (Claude + Copilot)

> **Status:** plan only; proceeding autonomously.
>
> **Goal:** add top-level `ai.agents` that fans out to Claude and
> Copilot — both use the same markdown-with-YAML-frontmatter shape
> for agent files. Kiro intentionally excluded (JSON shape differs);
> Kiro agents remain on their existing per-CLI path.
>
> Also adds missing `ai.claude.agents` per-CLI option so Claude can
> receive the fanout and consumers can override per-CLI.

## Shape analysis

| Ecosystem | Native path                      | Format                      | Current factory option                                                   |
| --------- | -------------------------------- | --------------------------- | ------------------------------------------------------------------------ |
| Claude    | `.claude/agents/<name>.md`       | markdown + YAML frontmatter | NONE (upstream `programs.claude-code.agents` exists; we don't expose it) |
| Copilot   | `.github/agents/<name>.agent.md` | markdown + YAML frontmatter | `ai.copilot.agents` (attrsOf lines), `ai.copilot.agentsDir`              |
| Kiro      | `.kiro/agents/<name>.json`       | JSON (role/tools/system)    | `ai.kiro.agents` (attrsOf lines-or-path), `ai.kiro.agentsDir`            |

Claude and Copilot share markdown+frontmatter format ergonomics.
Kiro is structurally different (JSON). Cross-ecosystem surface is
Claude+Copilot convergent; Kiro stays on its own surface.

## Scope

1. **Add `ai.agents` top-level** — `attrsOf (either lines path)`, matching
   Copilot's shape. Default `{}`.
2. **Add `ai.claude.agents` per-CLI option** — same shape. Route to
   upstream `programs.claude-code.agents` (identity translation — upstream
   accepts the same `attrsOf (either lines path)` shape). Absent today.
3. **Thread `mergedClaudeCopilotAgents`** through both transforms.
   Per-CLI wins on name collision (established pattern).
4. **Claude factory** consumes merged via HM route. No devenv (upstream
   devenv `claude.code` has no agents option — same story as lspServers
   for Claude devenv).
5. **Copilot factory** consumes merged via its existing
   `mapAttrs' → home.file`/`files` emission. Today it reads
   `cfg.agents` directly; switch to merged. HM + devenv parity.
6. **Kiro intentionally skipped.** `ai.kiro.agents` stays JSON-shaped;
   top-level `ai.agents` does NOT fan to Kiro. Document the divergence
   on the option.

## Merge naming

To avoid ambiguity with Kiro's differently-shaped agents option,
the merge alias in transforms is `mergedClaudeCopilotAgents`
(explicit about scope) rather than `mergedAgents`. Alternative names
considered and rejected:

- `mergedAgents` — implies all three, but Kiro doesn't participate
- `mergedMarkdownAgents` — accurate about shape but verbose
- `mergedAgentDocs` — ambiguous

`mergedClaudeCopilotAgents` is the clearest.

## Out of scope

- **Unifying Kiro JSON agents with markdown+frontmatter agents.**
  The shapes are semantically different (Kiro defines role/tools
  via JSON; Claude/Copilot define agent instructions via markdown
  body + frontmatter metadata). Unifying would require a schema
  translator — separate design.
- **`agentsDir` cross-ecosystem.** Both Claude and Copilot could have
  top-level `ai.agentsDir` fanned to their per-CLI agentsDir, but
  Claude doesn't have agentsDir in our factory today. Skipped.
- **Typed agent schema.** Currently freeform markdown. Typed fields
  (name, description, tools, allowed-tools) would be a follow-up.

## Plan

### 1. `sharedOptions.nix` — add `ai.agents`

```nix
agents = lib.mkOption {
  type = lib.types.attrsOf (lib.types.either lib.types.lines lib.types.path);
  default = {};
  description = ''
    Markdown+frontmatter agent definitions fanned out to Claude and
    Copilot. Each entry becomes a file:
    Claude → ~/.claude/agents/<name>.md,
    Copilot → .github/agents/<name>.agent.md (devenv) or
              ~/.copilot/agents/<name>.agent.md (HM, via existing
              Copilot agents wiring).
    Kiro intentionally excluded — Kiro's agent format is JSON with
    different semantic fields; use `ai.kiro.agents` directly for
    that ecosystem.
  '';
};
```

### 2. `hmTransform.nix` + `devenvTransform.nix` — thread merge

```nix
mergedClaudeCopilotAgents = config.ai.agents // (cfg.agents or {});
```

Passed to per-CLI config callback alongside other `merged*` args.

### 3. `mkClaude.nix` — add `ai.claude.agents` + HM wiring

```nix
# In shared options block:
agents = lib.mkOption {
  type = lib.types.attrsOf (lib.types.either lib.types.lines lib.types.path);
  default = {};
  description = "Claude-specific agents; merged with ai.agents. HM only (upstream devenv has no agents option).";
};

# In HM config:
programs.claude-code.agents = mergedClaudeCopilotAgents;
```

Devenv: absorb the merged arg via `...` (unused; upstream devenv has no
agents surface).

### 4. `mkCopilot.nix` — consume merged

Switch HM + devenv agent emission blocks from `cfg.agents` to
`mergedClaudeCopilotAgents`. The existing `agents` vs `agentsDir`
assertion stays — user still can't mix inline + dir on the per-CLI
side, but top-level + per-CLI merges freely.

### 5. `mkKiro.nix` — no change

Kiro's `ai.kiro.agents` is JSON-shaped; top-level `ai.agents` is
markdown-shaped. Kiro signature absorbs the new merged arg via
`...` or ignores it explicitly. Kiro's existing JSON-agents
emission is untouched.

### 6. Stubs

`programs.claude-code` stub is already `attrsOf anything`
(collapsed in `732ca51`), so `.agents` lands without stub edits.
No stub changes required.

### 7. Tests

- HM: `ai.agents.reviewer = "# ..."` with `ai.claude.enable = true`
  → `config.programs.claude-code.agents.reviewer == "# ..."`.
- HM: same with `ai.copilot.enable = true` →
  `config.home.file.".copilot/agents/reviewer.agent.md".text == "# ..."`.
- Devenv: Copilot devenv agent write to `.github/agents/reviewer.agent.md`.
- Precedence: `ai.agents.x` + `ai.claude.agents.x` → Claude-specific
  wins.
- Kiro independence: `ai.agents.foo = "# ..."` + `ai.kiro.enable = true`
  does NOT cause Kiro emission (no `.kiro/agents/foo.*` file).

### 8. Plan.md close-out

Update the "Expose remaining upstream HM claude-code options" bullet
to note agents partially covered here (Claude+Copilot cross-ecosystem);
commands + hooks still pending.

### 9. Commit

Single commit: `feat(ai): cross-ecosystem ai.agents for Claude + Copilot`.

## Size estimate

~40 lines factory + ~50 lines tests + 1 commit.

## Review checklist

- [ ] `ai.agents` declared in sharedOptions with Kiro-excluded note.
- [ ] `ai.claude.agents` added to mkClaude.
- [ ] Both transforms compute `mergedClaudeCopilotAgents`.
- [ ] Claude HM routes merged to `programs.claude-code.agents`.
- [ ] Copilot HM + devenv consume merged (not cfg.agents).
- [ ] Kiro untouched.
- [ ] Tests cover fanout, precedence, and Kiro independence.
- [ ] Devenv test uses `.github/agents/...agent.md` path (post-restructure).
- [ ] Commit message notes Kiro exclusion rationale.
