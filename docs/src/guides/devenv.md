# DevEnv Deep Dive

Detailed reference for all devenv module options. See
[DevEnv Setup](../getting-started/devenv.md) for installation and
quickstart.

## Module Index

| Module    | Import path             | Purpose               |
| --------- | ----------------------- | --------------------- |
| `ai`      | `devenvModules.ai`      | Unified config fanout |
| `copilot` | `devenvModules.copilot` | Copilot config        |
| `kiro`    | `devenvModules.kiro`    | Kiro config           |
| `default` | `devenvModules.default` | All of the above      |

## ai.\* Options (DevEnv)

Same interface as the HM `ai.*` module. See
[The Unified ai.\* Module](../concepts/unified-ai-module.md).

| Option                    | Type                      | Default | Description                 |
| ------------------------- | ------------------------- | ------- | --------------------------- |
| `ai.enable`               | bool                      | `false` | Master switch               |
| `ai.enableClaude`         | bool                      | `false` | Generate `.claude/` config  |
| `ai.enableCopilot`        | bool                      | `false` | Generate `.copilot/` config |
| `ai.enableKiro`           | bool                      | `false` | Generate `.kiro/` config    |
| `ai.skills`               | attrsOf path              | `{}`    | Shared skill directories    |
| `ai.instructions`         | attrsOf instructionModule | `{}`    | Shared instructions         |
| `ai.lspServers`           | attrsOf lspServerModule   | `{}`    | Typed LSP server defs       |
| `ai.settings.model`       | nullOr str                | `null`  | Default model               |
| `ai.settings.telemetry`   | nullOr bool               | `null`  | Telemetry toggle            |
| `ai.environmentVariables` | attrsOf str               | `{}`    | Shared env vars             |

## claude.code.\* Options

Direct Claude Code configuration for project-local settings.

| Option                   | Type             | Default | Description               |
| ------------------------ | ---------------- | ------- | ------------------------- |
| `claude.code.enable`     | bool             | `false` | Enable Claude Code config |
| `claude.code.env`        | attrsOf str      | `{}`    | Environment variables     |
| `claude.code.mcpServers` | attrsOf mcpEntry | `{}`    | MCP server entries        |

## copilot.\* Options

| Option                 | Type                    | Default | Description           |
| ---------------------- | ----------------------- | ------- | --------------------- |
| `copilot.enable`       | bool                    | `false` | Enable Copilot config |
| `copilot.settings`     | attrs                   | `{}`    | Copilot settings      |
| `copilot.instructions` | attrsOf (lines or path) | `{}`    | Instruction files     |
| `copilot.skills`       | attrsOf path            | `{}`    | Skill directories     |

## kiro.\* Options

| Option          | Type                    | Default | Description        |
| --------------- | ----------------------- | ------- | ------------------ |
| `kiro.enable`   | bool                    | `false` | Enable Kiro config |
| `kiro.settings` | attrs                   | `{}`    | Kiro settings      |
| `kiro.steering` | attrsOf (lines or path) | `{}`    | Steering files     |
| `kiro.skills`   | attrsOf path            | `{}`    | Skill directories  |

## Differences from Home-Manager

| Aspect            | Home-Manager                            | DevEnv                                    |
| ----------------- | --------------------------------------- | ----------------------------------------- |
| Config location   | `~/.claude/`, `~/.copilot/`, `~/.kiro/` | `.claude/`, `.copilot/`, `.kiro/`         |
| Persistence       | Survives shell exit                     | Recreated on `devenv shell` entry         |
| MCP servers       | `services.mcp-servers` (systemd)        | Inline per-CLI (`claude.code.mcpServers`) |
| Stacked workflows | Module with git presets                 | Manual skill wiring via `ai.skills`       |
| Fragment pipeline | N/A                                     | `files.*` materialization                 |

## Generated Files

DevEnv writes config to project-local dotfiles. These are recreated on
every shell entry and should be in `.gitignore`:

```gitignore
.claude/rules/
.claude/skills/
.claude/settings.json
.copilot/
.kiro/
```

## Overlay Access in DevEnv

DevEnv does not automatically apply overlays. To access content packages
or MCP servers, compose the overlays manually:

```nix
{inputs, pkgs, lib, ...}: let
  contentPkgs = pkgs.extend (lib.composeManyExtensions [
    (import "${inputs.agentic-tools}/packages/coding-standards" {})
    (import "${inputs.agentic-tools}/packages/stacked-workflows" {})
  ]);
in {
  # Now use contentPkgs.coding-standards, contentPkgs.stacked-workflows-content
}
```

For MCP server packages, apply the mcp-servers overlay:

```nix
mcpPkgs = pkgs.extend (import "${inputs.agentic-tools}/packages/mcp-servers" {
  inherit inputs;
});
# mcpPkgs.nix-mcp-servers.github-mcp, etc.
```
