# Module evaluation tests for home-manager modules.
# Verifies that modules evaluate without errors for representative configs.
{
  lib,
  pkgs,
  self,
}: let
  # Minimal home-manager evaluation harness.
  # Stubs enough of the HM interface for module options to evaluate.
  evalModule = modules:
    lib.evalModules {
      modules =
        modules
        ++ [
          {
            config._module.args = {
              inherit pkgs;
              osConfig = {};
            };
          }
          ({lib, ...}: {
            options = {
              assertions = lib.mkOption {
                type = lib.types.listOf lib.types.anything;
                default = [];
              };
              home = {
                activation = lib.mkOption {
                  type = lib.types.attrsOf lib.types.anything;
                  default = {};
                };
                file = lib.mkOption {
                  type = lib.types.attrsOf lib.types.anything;
                  default = {};
                };
                packages = lib.mkOption {
                  type = lib.types.listOf lib.types.package;
                  default = [];
                };
              };
              programs = {
                git.settings = lib.mkOption {
                  type = lib.types.attrsOf lib.types.anything;
                  default = {};
                };
                mcp = {
                  enable = lib.mkEnableOption "mcp";
                  servers = lib.mkOption {
                    type = lib.types.attrsOf lib.types.anything;
                    default = {};
                  };
                };
              };
              services.mcp-servers = lib.mkOption {
                type = lib.types.attrsOf lib.types.anything;
                default = {};
              };
            };
          })
        ];
    };

  # Test: copilot-cli module evaluates with enable = false (no-op)
  copilotDisabled = evalModule [
    self.homeManagerModules.copilot-cli
    {config.programs.copilot-cli.enable = false;}
  ];

  # Test: kiro-cli module evaluates with enable = false (no-op)
  kiroDisabled = evalModule [
    self.homeManagerModules.kiro-cli
    {config.programs.kiro-cli.enable = false;}
  ];

  # Test: MCP server module evaluates with all servers disabled
  mcpDisabled = evalModule [
    self.homeManagerModules.mcp-servers
  ];

  # Test: stacked-workflows module evaluates with enable = false (no-op)
  swsDisabled = evalModule [
    self.homeManagerModules.stacked-workflows
    {config.stacked-workflows.enable = false;}
  ];
in {
  copilot-cli-eval = pkgs.runCommand "copilot-cli-eval" {} ''
    echo "copilot-cli module evaluation: ${
      if copilotDisabled.config.programs.copilot-cli.enable
      then "enabled"
      else "disabled (no-op)"
    }" > $out
  '';

  kiro-cli-eval = pkgs.runCommand "kiro-cli-eval" {} ''
    echo "kiro-cli module evaluation: ${
      if kiroDisabled.config.programs.kiro-cli.enable
      then "enabled"
      else "disabled (no-op)"
    }" > $out
  '';

  mcp-servers-eval = pkgs.runCommand "mcp-servers-eval" {} ''
    echo "mcp-servers module evaluation: ${
      if mcpDisabled.config.services.mcp-servers.enable or false
      then "enabled"
      else "disabled (no-op)"
    }" > $out
  '';

  stacked-workflows-eval = pkgs.runCommand "stacked-workflows-eval" {} ''
    echo "stacked-workflows module evaluation: ${
      if swsDisabled.config.stacked-workflows.enable
      then "enabled"
      else "disabled (no-op)"
    }" > $out
  '';
}
