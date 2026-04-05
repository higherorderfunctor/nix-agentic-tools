# Kiro CLI devenv integration.
# Mirrors devenv's claude.nix pattern for Kiro's file layout.
#
# Generates:
#   .kiro/settings/mcp.json — MCP server config
#   .kiro/settings/cli.json — CLI settings (if configured)
{
  pkgs,
  lib,
  config,
  ...
}: let
  cfg = config.kiro;
  mcpCommon = import ./mcp-common.nix {inherit lib;};

  # Build MCP config
  mcpServers = lib.mapAttrs (_: mcpCommon.transformMcpServer) cfg.mcpServers;

  mcpContent =
    if cfg.mcpServers == {}
    then null
    else {inherit mcpServers;};
in {
  options.kiro = {
    enable = lib.mkEnableOption "Kiro CLI integration";

    mcpServers = lib.mkOption {
      type = mcpCommon.mcpServerType;
      default = {};
      description = "MCP servers to configure for Kiro.";
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Kiro CLI settings (written to .kiro/settings/cli.json).";
    };
  };

  config = lib.mkIf cfg.enable {
    files =
      lib.optionalAttrs (mcpContent != null) {
        ".kiro/settings/mcp.json".json = mcpContent;
      }
      // lib.optionalAttrs (cfg.settings != {}) {
        ".kiro/settings/cli.json".json = cfg.settings;
      };
  };
}
