# Factory contracts for this owner or shared primitive.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) checkRows rejectsChange;
  inherit (import ../../lib/testing/factory-harness.nix {inherit lib pkgs harness;}) ai evalService mkServiceServerDef mkTest;

  stdio = {
    command = "hello";
    package = pkgs.hello;
    type = "stdio";
  };
in {
  checks = {
    factory-mcpServer-commonSchema = mkTest "mcpServer-commonSchema" (
      let
        # Force the transport leaf: null permits inference, but an explicit
        # string must not bypass the enum check.
        readType = config:
          (lib.evalModules {
            modules = [ai.mcpServer.commonSchema {inherit config;}];
          }).config.type;
      in
        checkRows "MCP server common schema" {
          "an unknown explicit transport cannot pass as a string" = rejectsChange readType {
            expected = "stdio";
            invalid = stdio // {type = "unsupported-transport";};
            valid = stdio;
          };
        }
    );

    factory-mcpServer-mkMcpServer = mkTest "mkMcpServer" (
      let
        instance = ai.mcpServer.mkMcpServer {
          defaults = stdio // {args = ["--from-defaults"];};
          name = "test";
        } {args = ["--from-consumer"];};
      in
        checkRows "MCP server factory" {
          # Pin membership and multiplicity without specifying relative order.
          "argument definitions concatenate rather than replacing either writer" =
            lib.sort builtins.lessThan instance.args == ["--from-consumer" "--from-defaults"];
        }
    );

    factory-mcpServer-service-host = mkTest "mcpServer-service-host" (
      let
        audited = {serverDef = native {honorsServiceHost = true;};};
        native = mkServiceServerDef "test-mcp --http";
        readHost = input: (evalService input).config.server.service.host;
        unsupported = {serverDef = native {honorsServiceHost = false;};};
      in
        checkRows "MCP HTTP service bind host" {
          # A native mode must state its audit result. This is the structural guard
          # that turns a future bridge -> native switch into an evaluation failure.
          "native mode requires an explicit audit even when the host is unset" = rejectsChange readHost {
            expected = "127.0.0.1";
            invalid = {serverDef = native {};};
            valid = audited;
          };
          # Any concrete value is rejected for an unsupported native mode, including
          # the old apparent default. Leaving it unset is the only accepted shape.
          "unsupported native mode rejects even the default address when explicitly set" = rejectsChange readHost {
            expected = "127.0.0.1";
            invalid = unsupported // {config.service.host = "127.0.0.1";};
            valid = unsupported;
          };
        }
    );
  };
}
