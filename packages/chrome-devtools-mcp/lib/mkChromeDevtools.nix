# Factory-of-factory for chrome-devtools-mcp. The raw-command shape carries the
# settings-generated argv; the package-module path renders the same mapping.
{
  lib,
  pkgs,
  ...
}: let
  extracted = import ./extracted.nix {inherit lib;};
  mcpLib = import ../../../lib/mcp.nix {inherit lib;};
  factory = lib.ai.mcpServer.mkMcpServer {
    name = "chrome-devtools-mcp";
    defaults = {
      package = pkgs.ai.mcpServers.chrome-devtools-mcp;
      type = "stdio";
      command = "chrome-devtools-mcp";
      args = [];
    };
  };
in
  consumerArgs: let
    evaluated = mcpLib.evalSettings "chrome-devtools-mcp" (consumerArgs.settings or {});
  in
    factory (
      consumerArgs
      // {
        args = extracted.settingsToArgs evaluated ++ (consumerArgs.args or []);
        settings = {};
      }
    )
