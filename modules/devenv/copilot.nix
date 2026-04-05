# GitHub Copilot devenv integration.
# Mirrors devenv's claude.nix pattern for Copilot's file layout.
#
# Generates:
#   .github/copilot-instructions.md — repo-wide instructions (via files.*)
#   .github/instructions/*.instructions.md — per-package scoped instructions
# GitHub Copilot devenv integration.
# Mirrors devenv's claude.nix pattern for Copilot's file layout.
#
# Generates:
#   .github/copilot-instructions.md — repo-wide instructions (via files.*)
#   .github/instructions/*.instructions.md — per-package scoped instructions
{
  pkgs,
  lib,
  config,
  ...
}: let
  cfg = config.copilot;
  mcpCommon = import ./mcp-common.nix {inherit lib;};
in {
  options.copilot = {
    enable = lib.mkEnableOption "GitHub Copilot integration";

    mcpServers = lib.mkOption {
      type = mcpCommon.mcpServerType;
      default = {};
      description = "MCP servers to configure for Copilot.";
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Copilot settings (written to .copilot/config.json).";
    };
  };

  config = lib.mkIf cfg.enable {
    files = let
      mcpServers = lib.mapAttrs (_: mcpCommon.transformMcpServer) cfg.mcpServers;
    in
      lib.optionalAttrs (cfg.mcpServers != {}) {
        ".vscode/mcp.json".json = {inherit mcpServers;};
      }
      // lib.optionalAttrs (cfg.settings != {}) {
        ".copilot/config.json".json = cfg.settings;
      };
  };
}
