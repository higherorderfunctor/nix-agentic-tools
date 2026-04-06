# DevEnv Setup

Per-project AI tool configuration via devenv. Config lives with the
project and activates on shell entry.

## 1. Add the input

```yaml
# devenv.yaml
inputs:
  nix-agentic-tools:
    url: github:higherorderfunctor/nix-agentic-tools
    inputs:
      nixpkgs:
        follows: nixpkgs
```

## 2. Import the modules

```nix
# devenv.nix
{inputs, ...}: {
  imports = [
    inputs.nix-agentic-tools.devenvModules.default
  ];
}
```

This imports `ai`, `copilot`, and `kiro` devenv modules. Import
individually if preferred:

```nix
imports = [inputs.nix-agentic-tools.devenvModules.ai];
```

## 3. Minimal configuration

```nix
{inputs, pkgs, ...}: {
  imports = [inputs.nix-agentic-tools.devenvModules.default];

  ai = {
    enable = true;
    claude.enable = true;
  };

  claude.code.enable = true;
}
```

## 4. Full configuration example

```nix
{inputs, pkgs, lib, ...}: let
  # Apply overlays to get content packages
  contentPkgs = pkgs.extend (lib.composeManyExtensions [
    (import "${inputs.nix-agentic-tools}/packages/coding-standards" {})
    (import "${inputs.nix-agentic-tools}/packages/stacked-workflows" {})
  ]);
in {
  imports = [inputs.nix-agentic-tools.devenvModules.default];

  # ── Packages ──────────────────────────────────────────────────────
  packages = with pkgs; [nixd marksman taplo];

  # ── Unified AI config ─────────────────────────────────────────────
  ai = {
    enable = true;
    claude.enable = true;
    copilot.enable = true;
    kiro.enable = true;

    skills = {
      stack-fix = "${contentPkgs.stacked-workflows-content.passthru.skillsDir}/stack-fix";
      stack-plan = "${contentPkgs.stacked-workflows-content.passthru.skillsDir}/stack-plan";
    };
  };

  # ── Claude Code ────────────────────────────────────────────────────
  claude.code = {
    enable = true;
    env.ENABLE_LSP_TOOL = "1";

    mcpServers.github-mcp = {
      type = "stdio";
      command = "${pkgs.nix-mcp-servers.github-mcp}/bin/github-mcp-server";
      args = ["--stdio"];
    };
  };

  # ── Copilot ────────────────────────────────────────────────────────
  copilot = {
    enable = true;
    settings.model = "gpt-4o";
  };

  # ── Kiro ───────────────────────────────────────────────────────────
  kiro = {
    enable = true;
    settings.chat.defaultModel = "claude-sonnet-4";
  };
}
```

## 5. Verify

```bash
devenv shell

# Check generated files
ls .claude/rules/         # Claude instructions
ls .claude/skills/        # Skills (symlinks to store)
ls .claude/settings.json  # Claude settings
ls .copilot/              # Copilot config
ls .kiro/                 # Kiro config
```

## What gets generated

DevEnv writes config to project-local dotfiles via `files.*`:

| ai.\* option   | Claude                  | Copilot                 | Kiro                      |
| -------------- | ----------------------- | ----------------------- | ------------------------- |
| `skills`       | `.claude/skills/`       | `.github/skills/`       | `.kiro/skills/`           |
| `instructions` | `.claude/rules/`        | `.github/instructions/` | `.kiro/steering/`         |
| `settings`     | `.claude/settings.json` | `.copilot/config.json`  | `.kiro/settings/cli.json` |
| `mcpServers`   | `.claude/settings.json` | `.copilot/mcp.json`     | `.kiro/settings/mcp.json` |

> **Note:** Generated files are `.gitignore`'d. They're recreated on
> every `devenv shell` entry.

## Differences from Home-Manager

| Aspect            | Home-Manager                     | DevEnv                     |
| ----------------- | -------------------------------- | -------------------------- |
| Scope             | System-wide (`~/.claude/`)       | Project-local (`.claude/`) |
| Persistence       | Survives shell exit              | Recreated on shell entry   |
| MCP servers       | `services.mcp-servers` (systemd) | Inline per-CLI config      |
| Stacked workflows | Module with git presets          | Manual skill wiring        |
| Fragment pipeline | N/A                              | `files.*` materialization  |

## Next steps

- [The Unified ai.\* Module](../concepts/unified-ai-module.md) — same
  module, both HM and devenv
- [Overlays & Packages](../concepts/overlays-packages.md) — what the
  overlay provides
- [Fragments & Composition](../concepts/fragments.md) — composable
  instruction building blocks
