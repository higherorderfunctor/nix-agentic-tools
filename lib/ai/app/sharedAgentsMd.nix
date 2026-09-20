# One keyed writer for every repository-local AGENTS.md target shared by
# AGENTS.md-standard runtimes. Runtime factories contribute named context/rule
# units; this module renders each filename once after the module system has
# deduplicated equal definitions and rejected divergent definitions for a key.
# Applicable public final-file entries from enabled runtimes
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
  deliveryMethod = import ../deliveryMethod.nix {inherit lib;};
  deliveryOptions = import ../delivery-options.nix {inherit lib;};
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
        else (finalEntry.content or {}).text or null;
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
  # Discover public app records from their option shape, including downstream
  # runtimes absent from this repository's first-party registry.
  runtimeNames = builtins.attrNames (lib.filterAttrs (_name: runtime:
    runtime ? enable && runtime ? files && runtime ? methodFor)
  options.ai);
  backend =
    if isDevenv
    then "devenv"
    else "hm";
  sharedTarget = runtime: path:
    isDevenv
    && options.ai.${runtime} ? normalized.context
    && config.ai.${runtime}.context.filename == path
    && builtins.hasAttr path config.ai.internal.agentsMd;
  claims = lib.concatMap (runtime: let
    cfg = config.ai.${runtime};
  in
    lib.optionals cfg.enable (lib.mapAttrsToList (path: entry: {
      inherit entry path runtime;
      method =
        if entry.method != null
        then entry.method
        else
          cfg.methodFor {
            inherit backend path;
            inherit (entry) facts;
            default = deliveryMethod.byRule;
          };
    }) (lib.filterAttrs (_path: entry: entry != null) cfg.files)))
  runtimeNames;
  byPath = lib.groupBy (claim: claim.path) claims;
  contested = lib.filterAttrs (_path: entries: builtins.length entries > 1) byPath;
  collisionAssertions =
    lib.mapAttrsToList (path: entries: {
      assertion = lib.all (claim: sharedTarget claim.runtime path) entries;
      message = "ai: ${lib.concatMapStringsSep ", " (claim: claim.runtime) entries} all deliver `${path}`; a contested path needs one owner. Give one runtime a distinct path; only a shared AGENTS.md context target is arbitrated.";
    })
    contested;
  methodAssertions =
    lib.mapAttrsToList (path: entries: {
      assertion = builtins.length (lib.unique (map (claim: claim.method) entries)) <= 1;
      message = "ai: `${path}` is delivered by different methods; one path has one owner and one method.";
    })
    contested;
  # A public claim on an aggregate also competes with its generated owner even
  # when no second runtime supplies a public override. That owner is a native
  # symlink; silently ignoring a claimant's method would lie about delivery.
  aggregateAssertions = map (claim: {
    assertion = sharedTarget claim.runtime claim.path && claim.method == "symlink";
    message = "ai.${claim.runtime}.files.\"${claim.path}\": the shared AGENTS.md aggregate requires a matching context target and one method (symlink).";
  }) (lib.filter (claim: isDevenv && builtins.hasAttr claim.path config.ai.internal.agentsMd) claims);
  sharedOverrideDefinitions = map (runtime: let
    inherit (config.ai.${runtime}) enable files;
  in
    lib.mkIf enable {
      ai.internal.files =
        lib.filterAttrs (
          filename: _entry: sharedTarget runtime filename
        )
        files;
    })
  runtimeNames;
in {
  options.ai.internal.agentsMd = lib.mkOption {
    type = lib.types.attrsOf fileType;
    default = {};
    internal = true;
    visible = false;
    description = "Repository-local keyed AGENTS.md compositions shared across runtimes.";
  };
  options.ai.internal.files = lib.mkOption {
    type = deliveryOptions.fileMapType;
    default = {};
    apply = runtimeFiles.validateFiles "internal";
    internal = true;
    visible = false;
    description = "Single-owner repository files rendered from cross-runtime compositions.";
  };

  config = lib.mkMerge [
    (lib.optionalAttrs (options ? assertions) {
      assertions = collisionAssertions ++ methodAssertions ++ aggregateAssertions;
    })
    (lib.optionalAttrs isDevenv (lib.mkMerge (
      [
        {assertions = sizeAssertions;}
        (lib.mkIf (config.ai.internal.agentsMd != {}) {
          # Do not inspect rendered bytes to discover whether a target exists.
          # The separate boolean inventory lets priority arbitration discard this
          # lazy default without forcing source-backed generated content.
          # Whole-entry priority, for the same reason mkCodex.nix states at its
          # own AGENTS.md entry: choosing between a file and no file reads the
          # rendered body, and a consumer who replaced this target must not pay
          # for reading a source they discarded. The `mkDefault` wrapper is what
          # defers that read until `filterOverrides` has kept the definition.
          ai.internal.files = lib.mapAttrs (_filename: text:
            lib.mkDefault (
              if text == ""
              then null
              else {content = {inherit text;};}
            ))
          generatedRendered;
        })
        (lib.mkIf (config.ai.internal.files != {}) {
          files = runtimeFiles.liveFiles config.ai.internal.files;
        })
      ]
      ++ sharedOverrideDefinitions
    )))
  ];
}
