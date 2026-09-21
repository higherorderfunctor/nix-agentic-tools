{lib, ...}: let
  inherit (lib) mkOption types;
  descriptions =
    lib.genAttrs [
      "aiCliDescriptions"
      "devToolDescriptions"
      "genericDescriptions"
      "gitToolDescriptions"
      "modelDescriptions"
      "skillDescriptions"
    ] (_:
      mkOption {
        default = {};
        type = types.attrsOf types.str;
        description = "Owner-provided descriptions for generated repository documentation.";
      });
in {
  options.documentation =
    descriptions
    // {
      mcpServerMeta = mkOption {
        default = {};
        description = "Owner-provided MCP server documentation.";
        type = types.attrsOf (types.submodule {
          options = {
            credentials = mkOption {type = types.str;};
            description = mkOption {type = types.str;};
          };
        });
      };
    };
}
