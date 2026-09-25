{
  lib,
  pkgs,
}: let
  contentScope = import ../lib/contentScope.nix {inherit lib;};
  modelExample = repo: rev: hash: ''
    let
      files = ["config.json" "model.safetensors" "modules.json" "tokenizer.json"];
    in
      inputs.nix-agentic-tools.lib.packaging.fetchHuggingFaceModel {
        inherit pkgs files;
        repoId = "minishlab/${repo}";
        rev = "${rev}";
        hash = "${hash}";
        license = lib.licenses.mit;
        # Lets evaluation check the files against model2vec's layouts.
        passthru = {inherit files;};
      }'';
  modelDescription = ''
    A package whose output is a model2vec model directory, such as a
    `lib.packaging.fetchHuggingFaceModel` result. Hugging Face ids are not
    accepted: they are unpinned, fail without network, and bypass the licence
    gate. Wrap local weights in a derivation. When the package lists its files
    in `passthru.files`, evaluation checks them against model2vec's accepted
    layouts.
  '';
  modelType = lib.types.submodule {
    options = {
      content = lib.mkOption {
        inherit (contentScope) type;
        example = ["code" "docs"];
        description = ''
          The content set this model serves. A search whose content set (its
          `--content`, or `defaultContent`) equals this set exactly uses this
          model. A scalar is coerced to a one-element list; `all` must appear
          alone and counts as `code config docs`. Enabled entries must have
          distinct sets.
        '';
      };
      description = lib.mkOption {
        type = lib.types.nullOr lib.types.nonEmptyStr;
        default = null;
        example = "Prose: READMEs, design notes, architecture docs.";
        description = ''
          What this model is for, shown to agents in the routing guidance and
          the subagent description. State the purpose only; the guidance
          already names the content.
        '';
      };
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether this entry routes searches. A disabled entry is left out of the package.";
      };
      model = lib.mkOption {
        type = lib.types.package;
        example = lib.literalExpression (modelExample "potion-base-32M" "1e5a03f8eeb2c98b928fbbd846f22f816360919f" "sha256-d9bGAm1XdYCwF63uODq5eD5Ow7utLaoxaxCYtVrqMTU=");
        description = modelDescription;
      };
    };
  };
  pathMappingType = lib.types.submodule {
    options = {
      content = lib.mkOption {
        type = lib.types.enum ["code" "config" "docs"];
        description = "Semble content category containing the matched files.";
      };
      language = lib.mkOption {
        type = lib.types.nonEmptyStr;
        example = "json";
        description = ''
          The language Semble assigns to the matched files: a language Semble
          bundles a grammar for (or an alias of one), or the language of a
          `grammars` package. The same language may appear in several
          entries, for example to split one language across content
          categories.
        '';
      };
      patterns = lib.mkOption {
        type = lib.types.nonEmptyListOf lib.types.nonEmptyStr;
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
        Languages must be unique and must not name a grammar Semble already
        bundles (or an alias of one): Semble would never load it.
      '';
    };
    pathMappings = lib.mkOption {
      type = lib.types.listOf pathMappingType;
      default = [];
      example = lib.literalExpression ''
        [
          {
            language = "bash";
            content = "code";
            patterns = [".envrc"];
          }
          {
            language = "json";
            content = "docs";
            patterns = ["docs/*.json"];
          }
          {
            language = "json";
            content = "config";
            patterns = ["*.json" "flake.lock"];
          }
        ]
      '';
      description = ''
        Path-to-language overrides for extensionless files, compound
        extensions, or repository-specific naming. Entries are tried in list
        order and the first matching pattern wins, so put narrower patterns
        first. A pattern may appear only once across all entries. A runtime
        override replaces the whole list.
      '';
    };
    models = lib.mkOption {
      type = lib.types.listOf modelType;
      default = [];
      example = lib.literalExpression ''
        [
          {
            model = potion-base-32M;
            content = "docs";
            description = "Prose: READMEs, design notes, architecture docs.";
          }
        ]
      '';
      description = ''
        Embedding models routed by content. A search uses the enabled entry
        whose content set equals the search's content set exactly (its
        `--content`, or `defaultContent`); any other set uses `defaultModel`.
        The CLI and the MCP server route the same way, the MCP server per
        tool call from its `content` argument.

        Anything other than the vanilla settings patches Semble, so any model
        edit changes the package and the cache guard clears the indexes on
        the next activation or shell entry. Indexes built with a model other
        than Semble's own live beside the default ones, suffixed with a hash
        of the model path. A runtime override replaces the whole list.
      '';
    };
    defaultContent = lib.mkOption {
      inherit (contentScope) default type;
      example = ["code" "docs"];
      description = ''
        The content a search uses when the call passes none: a plain
        `semble search`, and an MCP tool call without `content`. A call's
        `--content` replaces it wholesale. A scalar is coerced to a
        one-element list; `all` must appear alone.
      '';
    };
    defaultModel = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      example = lib.literalExpression (modelExample "potion-code-16M-v2" "e9d2a44ca6a05ac6685f3b23709ea57eb7352d5b" "sha256-EPzwepPyhcrNmU6lrmx2F5iCSbeSoKg5qZbErEEYHvw=");
      description = ''
        The model for a content set no `models` entry matches. null is
        Semble's built-in model, downloaded from Hugging Face on first use.
        While `models` has entries, the CLI prints a one-line warning each
        time it falls back to this model.

        ${modelDescription}
      '';
    };
    cli.instructions = optInFeatureOptions "CLI instructions";
    mcp = inheritedFeatureOptions "MCP server";
    subagent =
      optInFeatureOptions "semantic search subagent"
      // {
        interface = lib.mkOption {
          type = lib.types.enum ["cli" "mcp"];
          default = "cli";
          description = ''
            Whether the named agent reaches Semble through its CLI or MCP
            tools. On Kiro, `"mcp"` with `mcp.enable = false` gives the agent a
            private MCP server that the root session does not see. Claude and
            Codex cannot scope a server to one agent, so there that combination
            fails evaluation.
          '';
        };
      };
  };
}
