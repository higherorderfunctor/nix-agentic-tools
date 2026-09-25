# Direct typed MCP constructor for consumers that do not use the convenience
# module. The command is absolute. An unset `content` emits no argument, so the
# server decides: code, or with `--model K` in `args` (a `cli.models` package)
# entry K's content. A set `content` is always passed, `code` included.
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
        type = lib.types.nullOr contentScope.type;
        default = null;
        description = ''
          File-content categories the Semble MCP server searches by default. A
          scalar is coerced to a one-element list, and `all` must appear alone.
          null passes no `--content`: the server then searches code, or, when
          `args` select a `cli.models` entry with `--model`, that entry's
          content. Any other value is passed as `--content`, `code` included.
        '';
      };
    }
    consumerArgs;
  command =
    if evaluated.command != null
    then evaluated.command
    else if evaluated.package != null
    then "${evaluated.package}/bin/semble-mcp"
    else throw "lib.ai.mcpServers.mkSemble requires either `package` or `command`";
  contentErrors = lib.optionals (evaluated.content != null) (contentScope.errors "content" evaluated.content);
in
  if contentErrors != []
  then throw "lib.ai.mcpServers.mkSemble: ${lib.concatStringsSep "\n" contentErrors}"
  else
    removeAttrs evaluated ["content"]
    // {
      inherit command;
      args =
        evaluated.args
        ++ lib.optionals (evaluated.content != null) (["--content"] ++ contentScope.normalize evaluated.content);
    }
