# Home-Manager Deep Dive

Detailed reference for all home-manager module options. See
[Home-Manager Setup](../getting-started/home-manager.md) for
installation and quickstart.

## Module Index

| Module              | Import path                            | Purpose               |
| ------------------- | -------------------------------------- | --------------------- |
| `ai`                | `homeManagerModules.ai`                | Unified config fanout |
| `copilot-cli`       | `homeManagerModules.copilot-cli`       | Copilot CLI config    |
| `kiro-cli`          | `homeManagerModules.kiro-cli`          | Kiro CLI config       |
| `mcp-servers`       | `homeManagerModules.mcp-servers`       | MCP server management |
| `stacked-workflows` | `homeManagerModules.stacked-workflows` | Git presets + skills  |
| `default`           | `homeManagerModules.default`           | All of the above      |

## ai.\* Options

The unified module. See [The Unified ai.\* Module](../concepts/unified-ai-module.md)
for architecture details.

| Option                    | Type                      | Default | Description                     |
| ------------------------- | ------------------------- | ------- | ------------------------------- |
| `ai.enable`               | bool                      | `false` | Master switch                   |
| `ai.enableClaude`         | bool                      | `false` | Fan out to Claude Code          |
| `ai.enableCopilot`        | bool                      | `false` | Fan out to Copilot CLI          |
| `ai.enableKiro`           | bool                      | `false` | Fan out to Kiro CLI             |
| `ai.skills`               | attrsOf path              | `{}`    | Shared skill directories        |
| `ai.instructions`         | attrsOf instructionModule | `{}`    | Shared instructions (see below) |
| `ai.lspServers`           | attrsOf lspServerModule   | `{}`    | Typed LSP server defs           |
| `ai.settings.model`       | nullOr str                | `null`  | Default model                   |
| `ai.settings.telemetry`   | nullOr bool               | `null`  | Telemetry toggle                |
| `ai.environmentVariables` | attrsOf str               | `{}`    | Shared env vars                 |

## services.mcp-servers Options

| Option                                | Type                    | Default | Description              |
| ------------------------------------- | ----------------------- | ------- | ------------------------ |
| `servers.<name>.enable`               | bool                    | `false` | Enable this server       |
| `servers.<name>.settings.*`           | per-server              | varies  | Server-specific settings |
| `servers.<name>.settings.credentials` | nullOr (file or helper) | `null`  | Secret injection         |

See [MCP Server Configuration](./mcp-servers.md) for per-server details.

## stacked-workflows Options

| Option                                          | Type                           | Default  | Description            |
| ----------------------------------------------- | ------------------------------ | -------- | ---------------------- |
| `stacked-workflows.enable`                      | bool                           | `false`  | Master switch          |
| `stacked-workflows.gitPreset`                   | enum ["full" "minimal" "none"] | `"none"` | Git config preset      |
| `stacked-workflows.integrations.claude.enable`  | bool                           | `false`  | Wire skills to Claude  |
| `stacked-workflows.integrations.copilot.enable` | bool                           | `false`  | Wire skills to Copilot |
| `stacked-workflows.integrations.kiro.enable`    | bool                           | `false`  | Wire skills to Kiro    |

See [Stacked Workflows](./stacked-workflows.md) for preset details.

## programs.copilot-cli Options

| Option                                      | Type                    | Default | Description        |
| ------------------------------------------- | ----------------------- | ------- | ------------------ |
| `programs.copilot-cli.enable`               | bool                    | `false` | Enable Copilot CLI |
| `programs.copilot-cli.skills`               | attrsOf path            | `{}`    | Skill directories  |
| `programs.copilot-cli.instructions`         | attrsOf (lines or path) | `{}`    | Instruction files  |
| `programs.copilot-cli.lspServers`           | attrsOf attrs           | `{}`    | LSP server JSON    |
| `programs.copilot-cli.settings`             | attrs                   | `{}`    | Copilot settings   |
| `programs.copilot-cli.environmentVariables` | attrsOf str             | `{}`    | Env vars           |

## programs.kiro-cli Options

| Option                                   | Type                    | Default | Description       |
| ---------------------------------------- | ----------------------- | ------- | ----------------- |
| `programs.kiro-cli.enable`               | bool                    | `false` | Enable Kiro CLI   |
| `programs.kiro-cli.skills`               | attrsOf path            | `{}`    | Skill directories |
| `programs.kiro-cli.steering`             | attrsOf (lines or path) | `{}`    | Steering files    |
| `programs.kiro-cli.lspServers`           | attrsOf attrs           | `{}`    | LSP server JSON   |
| `programs.kiro-cli.settings`             | attrs                   | `{}`    | Kiro settings     |
| `programs.kiro-cli.environmentVariables` | attrsOf str             | `{}`    | Env vars          |

## Priority and Override Patterns

All `ai.*` values are injected at `mkDefault` priority (1000). To
override for a specific CLI:

```nix
# Shared default
ai.settings.model = "claude-sonnet-4";

# Copilot override (normal priority wins over mkDefault)
programs.copilot-cli.settings.model = "gpt-4o";
```

For git config, `stacked-workflows.gitPreset` also uses `mkDefault` on
every leaf, so you can override individual git settings at normal
priority in `programs.git.settings`.
