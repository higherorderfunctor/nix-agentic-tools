# Shared library — composes all lib sub-modules.
{lib}: let
  devshellLib = import ./devshell.nix {inherit lib;};
  fragmentsLib = import ./fragments.nix {inherit lib;};
  mcpLib = import ./mcp.nix {inherit lib;};
in {
  fragments = fragmentsLib;
  inherit (devshellLib) mkAgenticShell;
  inherit (mcpLib) evalSettings loadServer mkStdioEntry mkHttpEntry mkStdioConfig;
}
