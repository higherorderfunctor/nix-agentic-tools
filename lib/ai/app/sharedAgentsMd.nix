# One keyed writer for every repository-local AGENTS.md target shared by
# AGENTS.md-standard runtimes. Runtime factories contribute named context/rule
# units; this module renders each filename once after the module system has
# deduplicated equal definitions and rejected divergent definitions for a key.
{
  config,
  lib,
  options,
  ...
}: let
  isDevenv =
    lib.hasAttrByPath ["devenv" "root"] options
    && lib.hasAttrByPath ["files"] options;
  agentsmd = import ../transformers/agentsmd.nix {inherit lib;};
  deduplicatingType = {
    name,
    check,
  }:
    lib.types.mkOptionType {
      inherit check name;
      description = name;
      merge = loc: defs: let
        values = lib.unique (map (definition: definition.value) defs);
      in
        if builtins.length values == 1
        then builtins.head values
        else
          throw
          "The option `${lib.showOption loc}` has divergent contributions; AGENTS.md units with the same key must be byte-identical";
    };
  deduplicatedLines = deduplicatingType {
    name = "deduplicated Markdown text";
    check = builtins.isString;
  };
  deduplicatedNullableLines = deduplicatingType {
    name = "null or deduplicated Markdown text";
    check = value: value == null || builtins.isString value;
  };
  fileType = lib.types.submodule {
    options = {
      context = lib.mkOption {
        type = deduplicatedNullableLines;
        default = null;
        internal = true;
        visible = false;
        description = "Deduplicated always-on context body for this AGENTS.md target.";
      };
      maxBytes = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        internal = true;
        visible = false;
        description = "Optional runtime limit for the fully composed AGENTS.md target.";
      };
      rules = lib.mkOption {
        type = lib.types.attrsOf deduplicatedLines;
        default = {};
        internal = true;
        visible = false;
        description = "Rule bodies keyed by stable rule identity.";
      };
    };
  };
  rendered = lib.mapAttrs (_filename: value:
    agentsmd.renderKeyed {
      inherit (value) context rules;
    })
  config.ai.internal.agentsMd;
  sizeAssertions =
    lib.mapAttrsToList (filename: value: let
      text = rendered.${filename};
      size = builtins.stringLength text;
    in {
      assertion = value.maxBytes == null || size <= value.maxBytes;
      message = ''
        ${filename} renders to ${toString size} bytes, exceeding its configured
        limit (${toString value.maxBytes} bytes). Trim the contributing context
        or rules, or raise the runtime's document-size limit.
      '';
    })
    config.ai.internal.agentsMd;
in {
  options.ai.internal.agentsMd = lib.mkOption {
    type = lib.types.attrsOf fileType;
    default = {};
    internal = true;
    visible = false;
    description = "Repository-local keyed AGENTS.md compositions shared across runtimes.";
  };

  config = lib.optionalAttrs isDevenv (lib.mkMerge [
    {assertions = sizeAssertions;}
    (lib.mkIf (config.ai.internal.agentsMd != {}) {
      files = lib.mapAttrs' (filename: text:
        lib.nameValuePair filename {inherit text;})
      rendered;
    })
  ]);
}
