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
        readConfig = config:
          (lib.evalModules {
            modules = [ai.mcpServer.commonSchema {inherit config;}];
          }).config;
      in
        checkRows "MCP server common schema" {
          # The transport is nullable for renderer inference, but explicit
          # values must still pass the enum check.
          "an explicit transport must be a supported enum member" = rejectsChange (config: (readConfig config).type) {
            expected = "stdio";
            invalid = stdio // {type = "unsupported-transport";};
            valid = stdio;
          };
          "the command and arguments survive schema evaluation" = let
            config = readConfig (stdio // {args = ["--version"];});
          in
            config.command == "hello" && config.args == ["--version"];
        }
    );

    factory-mcpServer-mkMcpServer = mkTest "mkMcpServer" (
      let
        mkInstance = {
          defaults ? {},
          options ? {},
        }:
          ai.mcpServer.mkMcpServer {
            inherit options;
            defaults = stdio // defaults;
            name = "test";
          };
      in
        checkRows "MCP server factory" {
          "arguments from defaults and the consumer concatenate without extra members" = let
            instance = mkInstance {defaults.args = ["--from-defaults"];} {args = ["--from-consumer"];};
          in
            # Pin membership and multiplicity without specifying relative order.
            lib.sort builtins.lessThan instance.args == ["--from-consumer" "--from-defaults"];
          "consumer values can set custom options" = let
            instance = mkInstance {
              options.turboMode = lib.mkOption {
                default = false;
                type = lib.types.bool;
              };
            } {turboMode = true;};
          in
            instance.turboMode == true;
          "factory defaults survive construction with consumer arguments" = let
            instance = mkInstance {} {args = ["--version"];};
          in
            {inherit (instance) args command type;}
            == {
              args = ["--version"];
              command = "hello";
              type = "stdio";
            };
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
          # Bridge mode honors service.host in the shared mcp-proxy wrapper, so it
          # needs no per-server metadata declaration and still accepts overrides.
          "bridge mode accepts a host override without an audit" =
            readHost {
              config.service.host = "127.0.0.2";
              serverDef = mkServiceServerDef "bridge" {};
            }
            == "127.0.0.2";
          # A native mode must state its audit result. This is the structural guard
          # that turns a future bridge -> native switch into an evaluation failure.
          "native mode requires an explicit audit even when the host is unset" = rejectsChange readHost {
            expected = "127.0.0.1";
            invalid = {serverDef = native {};};
            valid = audited;
          };
          "supported native mode accepts a host override" =
            readHost (audited // {config.service.host = "127.0.0.2";}) == "127.0.0.2";
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
