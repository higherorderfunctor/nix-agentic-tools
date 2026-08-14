# Direct typed MCP constructor for consumers that do not use the convenience
# module. The command is absolute, and the default `["code"]` is represented by
# the server's native default (no redundant argument). The legal values and the
# argv lowering both come from `contentScope.nix`, shared with the module, so
# the two surfaces cannot disagree.
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

  # THROW rather than `assertions`. This path never evaluates a module's
  # `config`, so an assertions block would be silently discarded:
  # `lib/ai/mcpServer/mkMcpServer.nix` returns `eval.config` and nothing walks
  # it (same footgun as `packages/gitlab-mcp/modules/mcp-server.nix:323-324`).
  # The convenience module lowers these same strings to real assertions.
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
