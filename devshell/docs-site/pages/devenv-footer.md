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
    (import "${inputs.nix-agentic-tools}/packages/coding-standards" {})
    (import "${inputs.nix-agentic-tools}/packages/stacked-workflows" {})
  ]);
in {
  # Now use contentPkgs.coding-standards, contentPkgs.stacked-workflows-content
}
```

**Future:** MCP server packages will be exposed via a
`packages/mcp-servers` overlay, but that path does not yet exist on
this branch — do not copy this snippet until the MCP packaging
chunk lands.

```nix
# All AI binaries (CLIs + MCP servers) live under pkgs.ai.* after
# the nix-agentic-tools overlay is composed.
pkgs = import nixpkgs {
  inherit system;
  overlays = [inputs.nix-agentic-tools.overlays.default];
};
# pkgs.ai.github-mcp, pkgs.ai.claude-code, pkgs.ai.kiro-cli, etc.
```
