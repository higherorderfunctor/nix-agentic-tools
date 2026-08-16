{
  lib,
  pkgs,
}: let
  contentScope = import ../lib/contentScope.nix {inherit lib;};
  pathMappingType = lib.types.submodule {
    options = {
      content = lib.mkOption {
        type = lib.types.enum ["code" "config" "docs"];
        description = "Semble content category containing the matched files.";
      };
      language = lib.mkOption {
        type = lib.types.str;
        description = "Tree-sitter language name used to parse matched files.";
      };
      patterns = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = ''
          Filename globs or repository-relative path globs. Patterns without a
          slash match basenames at any depth; patterns with a slash match from
          the indexed repository root. Matching uses fnmatch semantics, where
          `*` can span `/`; use an exact path when directory depth matters.
        '';
      };
    };
  };
  inheritedFeatureOptions = description: {
    enable = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = "Whether to enable the Semble ${description}; null inherits the program-level enable value.";
    };
  };
  optInFeatureOptions = description: {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to enable the Semble ${description}; this is an explicit opt-in and does not inherit the program-level enable value.";
    };
  };
in {
  name = "semble";
  supportedRuntimes = ["claude" "codex" "kiro"];
  options = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to enable Semble's package and MCP integration. CLI instructions and the named subagent remain explicit opt-ins.";
    };
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.ai.semble;
      defaultText = lib.literalExpression "pkgs.ai.semble";
      description = "Semble package installed when at least one resolved runtime integration is active.";
    };
    grammars = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [];
      example = lib.literalExpression ''
        with pkgs.tree-sitter-grammars; [
          tree-sitter-awk
          tree-sitter-jq
        ]
      '';
      description = ''
        Additional Tree-sitter grammar packages used by Semble. Each package
        must expose a `language` attribute and a compiled `parser` output.
      '';
    };
    instructions.cli = optInFeatureOptions "CLI instructions";

    mcp =
      inheritedFeatureOptions "MCP server"
      // {
        content = lib.mkOption {
          inherit (contentScope) default description type;
        };
        rootExposure = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether the Semble MCP server is exposed to the root session. False is supported only for a Kiro MCP-backed named agent.";
        };
        pathMappings = lib.mkOption {
          type = lib.types.listOf pathMappingType;
          default = [];
          example = lib.literalExpression ''
            [
              {
                content = "config";
                language = "json";
                patterns = ["flake.lock" "devenv.lock"];
              }
            ]
          '';
          description = ''
            Ordered path-to-language overrides for extensionless files, compound
            extensions, or repository-specific naming. The first matching entry
            wins and its content category controls which Semble indexes include it.
          '';
        };
      };

    subagent =
      optInFeatureOptions "semantic search subagent"
      // {
        interface = lib.mkOption {
          type = lib.types.enum ["cli" "mcp"];
          default = "cli";
          description = "Whether the named agent reaches Semble through its CLI or MCP tools.";
        };
      };
  };
}
