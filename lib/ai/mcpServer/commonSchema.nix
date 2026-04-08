# Common typed attrset shape for every MCP server entry.
{lib, ...}: {
  options = {
    type = lib.mkOption {
      type = lib.types.enum [
        "http"
        "stdio"
      ];
      description = "Transport type for the MCP server.";
    };
    package = lib.mkOption {
      type = lib.types.package;
      description = "The MCP server package (derivation).";
    };
    command = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "The executable name inside `package`.";
    };
    args = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Arguments passed to the server binary.";
    };
    env = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Environment variables for the server process.";
    };
    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = "Server-specific settings passed through to the CLI config file.";
    };
    url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "HTTP endpoint URL (only for type = \"http\").";
    };
  };
}
