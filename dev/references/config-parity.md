# Config Parity Reference

Architectural principle for the nix-agentic-tools monorepo. Used by
repo-review's consistency-auditor to detect feature gaps across configuration
methods.

## Three Configuration Methods

| Method             | Location                               | Consumer                 | Delivery              |
| ------------------ | -------------------------------------- | ------------------------ | --------------------- |
| **lib/**           | `lib/mcp.nix`, `lib/ai/hm-helpers.nix` | Direct callers           | Manual function calls |
| **HM modules**     | `modules/`                             | NixOS/home-manager users | `home-manager switch` |
| **devenv modules** | `modules/devenv/`                      | Project contributors     | `devenv shell`        |

## Parity Matrix

Each row is a configuration surface. All three methods should support it. Gaps
are bugs unless marked N/A with rationale.

| Surface          | lib                           | HM                                                                                                     | devenv                                                                                                    |
| ---------------- | ----------------------------- | ------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------- |
| Agents           | N/A                           | `ai.agents`, per-CLI `.agents`                                                                         | `ai.agents`, per-CLI `.agents`                                                                            |
| Environment vars | N/A                           | `ai.environmentVariables`; Claude `native.settings.env`                                                | `ai.environmentVariables`; Claude `native.settings.env`                                                   |
| Hooks            | N/A                           | `ai.hooks` (Claude, Codex); per-CLI `.hooks` for claude, codex, kiro; Kimchi none (warns); copilot N/A | `ai.hooks` (Claude, Codex, Kimchi); per-CLI `.hooks` for claude, codex, kimchi, kiro; copilot N/A         |
| Context/rules    | N/A                           | `ai.context`, `ai.rules`, per-runtime                                                                  | `ai.context`, `ai.rules`, per-runtime                                                                     |
| LSP servers      | N/A                           | `ai.lspServers`; claude, copilot, kiro `.lspServers`                                                   | `ai.lspServers`, copilot + kiro `.lspServers`; Claude none (warns)                                        |
| MCP servers      | `mkStdioEntry`, `mkHttpEntry` | `ai.mcpServers`, per-CLI `.mcpServers`; Claude → personal plugin's `.mcp.json`                         | `ai.mcpServers`, per-CLI `.mcpServers`; Claude → project `.mcp.json`                                      |
| Permissions      | N/A                           | claude + codex `native.settings.permissions`; kimchi + kiro `.permissions`; copilot N/A                | claude + codex `native.settings.permissions`; kimchi `.permissions`; kiro none (global-only); copilot N/A |
| Settings         | N/A                           | Per-CLI `native.settings` (typed + freeform)                                                           | Per-CLI `native.settings` (typed + freeform)                                                              |
| Skills           | N/A                           | `ai.skills`, per-CLI `.skills`                                                                         | `ai.skills`, per-CLI `.skills`                                                                            |

### Per-Surface Notes

**Agents** -- `ai.agents` fans to Claude and Copilot, and its portable records
also reach Codex and Kimchi. Claude agents are `ai.agents` / `ai.claude.agents`,
each rendered to `.claude/agents/<name>.md`. Kiro is not fanned out: its agents
are a typed record lowered to its own v3 agent JSON, with a different tool
vocabulary (capability tags rather than Claude/Copilot tool names), so configure
them per-CLI.

**Environment vars** -- `ai.environmentVariables` is baked into the launcher
wrapper of every runtime that has one (Codex, Copilot, Kimchi, Kiro), on both
backends. It never touches the Home Manager session or the devenv shell. Claude
has no wrapper and does not consume the pool: its variables are
`ai.claude.native.settings.env`, written into `.claude/settings.json`.

**Hooks** -- `ai.hooks` is the portable pool. It reaches Claude
(`.claude/settings.json`) and Codex (`.codex/hooks.json`) on both backends, and
Kimchi's project `.kimchi/hooks.json` on devenv only. Per-CLI `.hooks` append
native entries after the shared ones: `ai.claude.hooks`, `ai.codex.hooks`, and
`ai.kimchi.hooks` (devenv only). Kimchi has no user-scope hook file Home Manager
can own, so under Home Manager the shared pool does not reach it and
`ai.kimchi.hooks` warns. Kiro hooks are not fanned out: `ai.kiro.hooks` (plus
`hooksDir` / `hooksJson`) are typed v3 records written to
`.kiro/hooks/<name>.json` on both backends. Copilot CLI has no hooks support.

**LSP servers** -- Claude reads LSP servers only from a plugin. Home Manager
delivers `ai.lspServers` / `ai.claude.lspServers` through the personal plugin's
`~/.claude/skills/nix-agentic-tools/.lsp.json`. devenv has no Claude LSP
delivery (an absent row in the delivery matrix, and a warning); Copilot and Kiro
get them on both backends.

**MCP servers** -- `ai.mcpServers` fans typed server records out to every
enabled runtime on both backends, and per-CLI `.mcpServers` adds or overrides
servers for one runtime. Claude reads them from the Home Manager personal
plugin's `~/.claude/skills/nix-agentic-tools/.mcp.json`, or from the project
`.mcp.json` under devenv; both are Nix-owned read-only files.

**Permissions** -- there is no portable pool; each runtime has its own option.
Claude uses `ai.claude.native.settings.permissions`, written into
`.claude/settings.json`, and Codex uses `ai.codex.native.settings.permissions`,
written into `.codex/config.toml` (`~/.codex/` under Home Manager); both on both
backends. Kimchi uses `ai.kimchi.permissions`, merged into
`~/.config/kimchi/harness/permissions.json` under Home Manager or the project
`.kimchi/permissions.json` under devenv. Kiro uses `ai.kiro.permissions`,
written to `~/.kiro/settings/permissions.yaml` under Home Manager only: Kiro
reads permissions from `~/.kiro/settings/` or `~/.kiro/workspace-roots/<hash>/`,
never a project `.kiro/`, so a devenv-written file would never be read.
Agent-local permission records stay part of each Kiro agent. Copilot has no
permissions option.

### Settings Type Coverage

Typed options with `freeformType` fallback for unknown keys:

| CLI     | HM typed keys                                                   | devenv typed keys                                               |
| ------- | --------------------------------------------------------------- | --------------------------------------------------------------- |
| Claude  | `ai.claude.native.settings.*` (generated from the binary)       | `ai.claude.native.settings.*` (generated from the binary)       |
| Copilot | `model`, `theme`                                                | `model`, `theme`                                                |
| Kiro    | `chat.defaultModel`, `chat.enableThinking`, `telemetry.enabled` | `chat.defaultModel`, `chat.enableThinking`, `telemetry.enabled` |

## Audit Checklist (for repo-review)

When auditing config parity:

1. For each HM module option, check if an equivalent devenv module option exists
   (and vice versa)
2. For each `ai.*` option, verify it fans out to ALL enabled ecosystems in BOTH
   HM and devenv contexts
3. Check that option names and types are consistent across methods
4. Verify that `mkDefault` is used for ai.\* fanout so per-ecosystem overrides
   win in both HM and devenv
5. Check that generated file paths match what each ecosystem actually reads
   (e.g., `.claude/rules/`, `.kiro/steering/`, `.github/instructions/`)
