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

For MCP server packages, apply the mcp-servers overlay:

```nix
mcpPkgs = pkgs.extend (import "${inputs.nix-agentic-tools}/packages/mcp-servers" {
  inherit inputs;
});
# mcpPkgs.nix-mcp-servers.github-mcp, etc.
```
