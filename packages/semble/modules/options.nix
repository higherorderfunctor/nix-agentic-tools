{
  lib,
  pkgs,
}: let
  contentScope = import ../lib/contentScope.nix {inherit lib;};
  sembleModels = import ../lib/models.nix {inherit lib;};
  modelType = lib.types.submodule ({name, ...}: {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether the CLI offers this model. Disabling `default` makes
          `--model` required for `semble search` and `semble find-related`.
          The MCP server ignores this flag for `default`.
        '';
      };
      model = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = null;
        example = lib.literalExpression ''
          inputs.nix-agentic-tools.lib.packaging.fetchFromHuggingFace {
            inherit pkgs;
            owner = "minishlab";
            repo = "potion-base-32M";
            rev = "1e5a03f8eeb2c98b928fbbd846f22f816360919f";
            files = ["config.json" "model.safetensors" "modules.json" "tokenizer.json"];
            hash = "sha256-d9bGAm1XdYCwF63uODq5eD5Ow7utLaoxaxCYtVrqMTU=";
            license = lib.licenses.mit;
          }
        '';
        description = ''
          A package whose output is a model2vec model directory, such as a
          `lib.packaging.fetchFromHuggingFace` result. null uses Semble's
          built-in default model. Hugging Face ids are not accepted: they are
          unpinned, fail without network, and bypass the licence gate. Wrap
          local weights in a derivation. When the package lists its files in
          `passthru.files`, evaluation checks them against model2vec's
          accepted layouts.
        '';
      };
      content = lib.mkOption {
        inherit (contentScope) default type;
        description = ''
          Content categories this model searches when the call passes no
          `--content`. A `--content` argument replaces this list for that call.
        '';
      };
      description =
        if name == "default"
        then
          lib.mkOption {
            type = lib.types.nullOr lib.types.nonEmptyStr;
            default = null;
            description = ''
              What the default model is for, shown to agents in the routing
              guidance. null uses a built-in description while `model` is null;
              once `model` is set, a description is required.
            '';
          }
        else
          lib.mkOption {
            type = lib.types.nonEmptyStr;
            description = ''
              What this model is for, shown to agents in the routing guidance.
              State the purpose only; the guidance already adds the invocation
              and the content categories.
            '';
          };
    };
  });
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
  pools = [["cli" "models"]];
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
    cli = {
      instructions = optInFeatureOptions "CLI instructions";

      # Models live under `cli` because only the CLI routes between them
      # today. If the MCP server gains per-call model selection, move `models`
      # to the program root. `models.default.model` ALSO selects the model of
      # this module's MCP server; `models.default.enable` is CLI-only.
      models = lib.mkOption {
        type = lib.types.attrsOf modelType;
        default = {};
        example = lib.literalExpression ''
          {
            default = {
              model = potion-code-16M-v2;
              description = "Source code: implementations, tests, build files.";
            };
            prose = {
              model = potion-base-32M;
              content = "docs";
              description = "Prose: READMEs, design notes, architecture docs.";
            };
          }
        '';
        description = ''
          Embedding models the Semble CLI routes between, by key. `default`
          always exists: the module defines it, so set
          `default.enable = false` rather than removing it. `semble search`
          uses `default`, and `semble --model <key> search` (or
          `semble search ... --model <key>`) uses another entry. Keys must
          match `${sembleModels.keyPattern}`.

          Anything other than the built-in default patches Semble, so any
          model edit changes the package and the cache guard clears the
          indexes on the next activation or shell entry. Indexes built with a
          non-default model live beside the default one, suffixed with a hash
          of the model path.

          A runtime override resolves per key: an entry replaces the portable
          entry with that key, and null removes it.
        '';
      };
    };

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
