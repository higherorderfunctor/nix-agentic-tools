# ai.\* Mapping Table

How each `ai.*` option maps to ecosystem-specific configuration.

## Settings

| `ai.*` option          | Claude Code                           | Copilot CLI                                 | Kiro CLI                                       |
| ---------------------- | ------------------------------------- | ------------------------------------------- | ---------------------------------------------- |
| `settings.model`       | `programs.claude-code.settings.model` | `programs.copilot-cli.settings.model`       | `programs.kiro-cli.settings.chat.defaultModel` |
| `settings.telemetry`   | --                                    | --                                          | `programs.kiro-cli.settings.telemetry.enabled` |
| `environmentVariables` | --                                    | `programs.copilot-cli.environmentVariables` | `programs.kiro-cli.environmentVariables`       |

## Content

| `ai.*` option         | Claude Code                 | Copilot CLI                                | Kiro CLI                            |
| --------------------- | --------------------------- | ------------------------------------------ | ----------------------------------- |
| `skills.{name}`       | `~/.claude/skills/{name}`   | `programs.copilot-cli.skills.{name}`       | `programs.kiro-cli.skills.{name}`   |
| `instructions.{name}` | `~/.claude/rules/{name}.md` | `programs.copilot-cli.instructions.{name}` | `programs.kiro-cli.steering.{name}` |
| `lspServers.{name}`   | `ENABLE_LSP_TOOL=1` (env)   | `lsp-config.json` (JSON)                   | `lsp.json` (JSON)                   |

## Instruction Frontmatter

| `instructionModule` field | Claude                        | Copilot                 | Kiro                                         |
| ------------------------- | ----------------------------- | ----------------------- | -------------------------------------------- |
| `text`                    | Body after frontmatter        | Body after frontmatter  | Body after frontmatter                       |
| `description` (non-empty) | `description:` in frontmatter | --                      | `description:` in frontmatter                |
| `paths` (set)             | `paths:` list in frontmatter  | `applyTo:` comma-joined | `fileMatchPattern:` + `inclusion: fileMatch` |
| `paths` (null)            | No frontmatter emitted        | `applyTo: "**"`         | `inclusion: always`                          |

## LSP Server Transforms

| `lspServerModule` field | Claude                   | Copilot                              | Kiro                             |
| ----------------------- | ------------------------ | ------------------------------------ | -------------------------------- |
| `package` + `binary`    | Sets `ENABLE_LSP_TOOL=1` | `command: /nix/store/.../binary`     | `command: /nix/store/.../binary` |
| `args`                  | --                       | `args: [...]`                        | `args: [...]`                    |
| `extensions`            | --                       | `fileExtensions: { ".ext": "name" }` | --                               |
| `initializationOptions` | --                       | Included if non-empty                | Included if non-empty            |

## File Locations (HM)

| Content type | Claude                      | Copilot                             | Kiro                         |
| ------------ | --------------------------- | ----------------------------------- | ---------------------------- |
| Skills       | `~/.claude/skills/{name}`   | `~/.copilot/skills/{name}`          | `~/.kiro/skills/{name}`      |
| Instructions | `~/.claude/rules/{name}.md` | `~/.copilot/instructions/{name}.md` | `~/.kiro/steering/{name}.md` |
| Settings     | `~/.claude/settings.json`   | `~/.copilot/config.json`            | `~/.kiro/settings/cli.json`  |
| MCP config   | `~/.claude/settings.json`   | `~/.copilot/mcp.json`               | `~/.kiro/settings/mcp.json`  |
| LSP config   | -- (env var only)           | `~/.copilot/lsp-config.json`        | `~/.kiro/lsp.json`           |

## File Locations (DevEnv)

| Content type | Claude                    | Copilot                          | Kiro                       |
| ------------ | ------------------------- | -------------------------------- | -------------------------- |
| Skills       | `.claude/skills/{name}`   | `.github/skills/{name}`          | `.kiro/skills/{name}`      |
| Instructions | `.claude/rules/{name}.md` | `.github/instructions/{name}.md` | `.kiro/steering/{name}.md` |
| Settings     | `.claude/settings.json`   | `.copilot/config.json`           | `.kiro/settings/cli.json`  |
| MCP config   | `.claude/settings.json`   | `.copilot/mcp.json`              | `.kiro/settings/mcp.json`  |

## Priority

All `ai.*` values are injected at `mkDefault` priority (1000).
Per-CLI options set at normal priority (100) always win:

```nix
ai.settings.model = "claude-sonnet-4";               # mkDefault (1000)
programs.copilot-cli.settings.model = "gpt-4o";      # normal (100) -- wins
```

This applies to all mapped values: skills, instructions,
environmentVariables, and lspServers.
