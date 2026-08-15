{
  lib,
  pkgs,
}: let
  runtimeType = lib.types.enum ["claude" "codex" "kiro"];
  runtimeListType = lib.types.listOf runtimeType;
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
  featureOptions = description: {
    enable = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = "Whether to enable the Semble ${description}; null inherits `semble.enable`.";
    };
    runtimes = lib.mkOption {
      type = lib.types.nullOr runtimeListType;
      default = null;
      description = "AI runtimes receiving the Semble ${description}; null inherits `semble.runtimes`.";
    };
  };
in {
  options.semble = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to enable Semble's MCP, instruction, and subagent integrations.";
    };
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.ai.semble;
      defaultText = lib.literalExpression "pkgs.ai.semble";
      description = "Semble package installed when at least one selected integration is active.";
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
    runtimes = lib.mkOption {
      type = runtimeListType;
      default = ["claude" "codex" "kiro"];
      description = "AI runtimes receiving enabled Semble integrations.";
    };

    instructions = featureOptions "CLI instructions";

    mcp =
      featureOptions "MCP server"
      // {
        content = lib.mkOption {
          type = lib.types.enum ["all" "code" "config" "docs"];
          default = "code";
          description = "File-content category indexed by the Semble MCP server.";
        };
      };

    subagent = featureOptions "semantic search subagent";
  };
}
