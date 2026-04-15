# Factory: MCP server → HM submodule options.
#
# Takes a server name, its definition (from loadServer), and a package
# resolver function. Returns a submodule function suitable for use in
# `types.submodule (mkServiceModule ...)`.
#
# The returned submodule declares:
#   enable          — bool
#   settings        — typed submodule from server's settingsOptions
#   env             — attrsOf str (escape hatch)
#   args            — listOf str (escape hatch)
#   scope           — readOnly enum (from meta.scope)
#   package?        — package (when server has a local package)
#   service.port?   — port (when server has HTTP mode + local package)
#   service.host?   — str (when server has HTTP mode + local package)
{lib}: let
  inherit
    (lib)
    literalExpression
    mkEnableOption
    mkOption
    optionalAttrs
    types
    ;

  serviceSchema = import ./serviceSchema.nix {inherit lib;};
in
  {
    name,
    serverDef,
    resolvePackage,
  }: _: {
    options =
      {
        enable = mkEnableOption "the ${name} MCP server";

        settings = mkOption {
          type = types.submodule {options = serverDef.settingsOptions;};
          default = {};
          description = "Server-specific configuration for ${name}.";
        };

        env = mkOption {
          type = types.attrsOf types.str;
          default = {};
          description = "Extra environment variables (escape hatch for options not yet in settings). Values end up in the Nix store -- use credentials for secrets.";
        };

        args = mkOption {
          type = types.listOf types.str;
          default = [];
          description = "Extra CLI arguments (escape hatch for options not yet in settings).";
        };

        scope = mkOption {
          type = types.enum ["local" "remote"];
          default = serverDef.meta.scope;
          readOnly = true;
          internal = true;
          description = "Whether the server is local (filesystem-bound) or remote.";
        };
      }
      // optionalAttrs (serviceSchema.hasLocalPackage serverDef) {
        package = mkOption {
          type = types.package;
          default = resolvePackage name;
          defaultText = literalExpression "pkgs.ai.mcpServers.${name}";
          description = "The ${name} package to use.";
        };
      }
      // optionalAttrs (serviceSchema.hasServiceCapability serverDef) {
        service = {
          port = mkOption {
            type = types.port;
            default = serverDef.meta.defaultPort;
            description = "Port to bind for the HTTP service.";
          };

          host = mkOption {
            type = types.str;
            default = "127.0.0.1";
            description = "Host/address to bind for the HTTP service.";
          };
        };
      };
  }
