# mkAgenticShell — standalone devshell with NixOS module system.
#
# Uses lib.evalModules (same pattern as devenv) to evaluate modules
# and produce a mkShell derivation. No home-manager or devenv dependency.
#
# Usage:
#   devShells.default = inputs.nix-agentic-tools.lib.mkAgenticShell pkgs {
#     mcpServers.github-mcp = {
#       enable = true;
#       command = "github-mcp-server";
#       args = ["--stdio"];
#     };
#     skills.stacked-workflows.enable = true;
#   };
{lib}: let
  mkAgenticShell = pkgs: userConfig: let
    modules =
      [
        # Core modules
        ../devshell/top-level.nix
        ../devshell/files.nix
        # Feature modules
        ../devshell/mcp-servers/default.nix
        ../devshell/skills/stacked-workflows.nix
        ../devshell/instructions/default.nix
      ]
      ++ (
        if builtins.isAttrs userConfig
        then [{config = userConfig;}]
        else if builtins.isList userConfig
        then userConfig
        else [userConfig]
      );

    evaluated = lib.evalModules {
      inherit modules;
      specialArgs = {inherit pkgs;};
    };
  in
    evaluated.config.shell;
in {
  inherit mkAgenticShell;
}
