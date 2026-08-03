# Direct typed MCP constructor for consumers that do not use the convenience
# module. The command is absolute and content="code" is represented by the
# server's native default (no redundant argument).
{
  lib,
  pkgs,
  ...
}: consumerArgs: let
  evaluated =
    lib.ai.mcpServer.mkMcpServer {
      name = "semble";
      defaults = {
        package = lib.mkDefault pkgs.ai.mcpServers.semble-mcp;
        type = lib.mkDefault "stdio";
      };
      options.content = lib.mkOption {
        type = lib.types.enum ["all" "code" "config" "docs"];
        default = "code";
        description = "File-content category indexed by the Semble MCP server.";
      };
    }
    consumerArgs;
  command =
    if evaluated.command != null
    then evaluated.command
    else if evaluated.package != null
    then "${evaluated.package}/bin/semble-mcp"
    else throw "lib.ai.mcpServers.mkSemble requires either `package` or `command`";
in
  removeAttrs evaluated ["content"]
  // {
    inherit command;
    args = evaluated.args ++ lib.optionals (evaluated.content != "code") ["--content" evaluated.content];
  }
