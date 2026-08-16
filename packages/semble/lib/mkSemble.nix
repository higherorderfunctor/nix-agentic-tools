# Direct typed MCP constructor for consumers that do not use the convenience
# module. The command is absolute and content="code" is represented by the
# server's native default (no redundant argument).
{
  lib,
  pkgs,
  ...
}: consumerArgs: let
  contentScope = import ./contentScope.nix {inherit lib;};
  evaluated =
    lib.ai.mcpServer.mkMcpServer {
      name = "semble";
      defaults = {
        package = lib.mkDefault pkgs.ai.mcpServers.semble-mcp;
        type = lib.mkDefault "stdio";
      };
      options.content = lib.mkOption {
        inherit (contentScope) default description type;
      };
    }
    consumerArgs;
  command =
    if evaluated.command != null
    then evaluated.command
    else if evaluated.package != null
    then "${evaluated.package}/bin/semble-mcp"
    else throw "lib.ai.mcpServers.mkSemble requires either `package` or `command`";
  contentErrors = contentScope.errors evaluated.content;
in
  if contentErrors != []
  then throw "lib.ai.mcpServers.mkSemble: ${lib.concatStringsSep "\n" contentErrors}"
  else
    removeAttrs evaluated ["content"]
    // {
      inherit command;
      args = evaluated.args ++ contentScope.toArgs evaluated.content;
    }
