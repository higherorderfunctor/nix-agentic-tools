# One keyed writer for every repository-local AGENTS.md target shared by
# AGENTS.md-standard runtimes. Runtime factories contribute named context/rule
# units; this module renders each filename once after the module system has
# deduplicated equal definitions and rejected divergent definitions for a key.
# Applicable public final-file entries from enabled Codex/Kiro runtimes
# arbitrate here too, before the single native sink, so replacement and
# tombstones cannot bypass ownership or their runtime's sole enable gate.
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
  runtimeFiles = import ../runtime-files.nix {inherit lib;};
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
      hasContent = lib.mkOption {
        type = lib.types.bool;
        default = false;
        internal = true;
        visible = false;
        description = "Whether normalized content should generate this AGENTS.md target.";
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
  allRendered = lib.mapAttrs (_filename: value:
    agentsmd.renderKeyed {
      inherit (value) context rules;
    })
  config.ai.internal.agentsMd;
  generatedRendered =
    lib.filterAttrs (
      filename: _text: config.ai.internal.agentsMd.${filename}.hasContent
    )
    allRendered;
  sizeAssertions =
    lib.mapAttrsToList (filename: value: let
      finalEntry = config.ai.internal.files.${filename} or null;
      finalText =
        if finalEntry == null
        then null
        else finalEntry.text or null;
      size =
        if finalText == null
        then null
        else builtins.stringLength finalText;
    in {
      assertion = value.maxBytes == null || size == null || size <= value.maxBytes;
      message = ''
        ${filename} renders to ${toString size} bytes, exceeding its configured
        limit (${toString value.maxBytes} bytes). Trim the contributing context
        or rules, replace the final inline file, or raise the runtime's
        document-size limit.
      '';
    })
    config.ai.internal.agentsMd;
  sharedRuntimeNames = ["codex" "kiro"];
  sharedOverrideDefinitions = map (runtime: let
    enabled = lib.attrByPath ["ai" runtime "enable"] false config;
    files = lib.attrByPath ["ai" runtime "files"] {} config;
  in
    lib.mkIf enabled {
      ai.internal.files =
        lib.filterAttrs (
          filename: _entry: builtins.hasAttr filename config.ai.internal.agentsMd
        )
        files;
    })
  sharedRuntimeNames;
in {
  options.ai.internal.agentsMd = lib.mkOption {
    type = lib.types.attrsOf fileType;
    default = {};
    internal = true;
    visible = false;
    description = "Repository-local keyed AGENTS.md compositions shared across runtimes.";
  };
  options.ai.internal.files = lib.mkOption {
    type = runtimeFiles.fileMapType;
    default = {};
    apply = runtimeFiles.validateFiles "internal";
    internal = true;
    visible = false;
    description = "Single-owner repository files rendered from cross-runtime compositions.";
  };

  config = lib.optionalAttrs isDevenv (lib.mkMerge (
    [
      {assertions = sizeAssertions;}
      (lib.mkIf (config.ai.internal.agentsMd != {}) {
        # Do not inspect rendered bytes to discover whether a target exists.
        # The separate boolean inventory lets priority arbitration discard this
        # lazy default without forcing source-backed generated content.
        ai.internal.files = lib.mapAttrs (_filename: text:
          lib.mkDefault (
            if text == ""
            then null
            else {inherit text;}
          ))
        generatedRendered;
      })
      (lib.mkIf (config.ai.internal.files != {}) {
        files = runtimeFiles.liveFiles config.ai.internal.files;
      })
    ]
    ++ sharedOverrideDefinitions
  ));
}
