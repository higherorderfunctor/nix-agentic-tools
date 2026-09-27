# One keyed writer for every repository-local AGENTS.md target shared by
# AGENTS.md-standard runtimes. Runtime factories contribute named context/rule
# units; this module renders each filename once after the module system has
# deduplicated equal definitions and rejected divergent definitions for a key.
# Applicable public final-file entries from enabled runtimes
# arbitrate here too, before the single writer, so replacement and
# tombstones cannot bypass ownership or their runtime's sole enable gate.
#
# The result lands as a read-only COPY, not a store symlink. A repository
# AGENTS.md is normally committed, and a committed symlink into /nix/store
# dangles on every other machine and on github.com. It goes through the same
# router as a runtime's files, as the pseudo-runtime `internal`, with one
# writer whose directory ledger at the project root claims each key it wrote
# and nothing else, so it also retracts a key that loses its last
# contributor. An entry that states its own `method` keeps it.
{
  config,
  lib,
  options,
  pkgs,
  ...
}: let
  isDevenv =
    lib.hasAttrByPath ["devenv" "root"] options
    && lib.hasAttrByPath ["files"] options;
  agentsmd = import ../transformers/agentsmd.nix {inherit lib;};
  aiCommon = import ../ai-common.nix {inherit lib;};
  aiTypes = import ../types.nix {inherit lib;};
  deliveryMethod = import ../deliveryMethod.nix {inherit lib;};
  deliveryOptions = import ../delivery-options.nix {inherit lib;};
  runtimeFiles = import ../runtime-files.nix {inherit lib;};
  adapters = import ../adapters {inherit lib pkgs;};
  writer = "materialize-agents-md";
  ledger = "materialize/agents-md.manifest";
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
      index = lib.mkOption {
        type = lib.types.attrsOf deduplicatedLines;
        default = {};
        internal = true;
        visible = false;
        description = "Rendered path-scoped index entries keyed by stable rule identity.";
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
      inherit (value) context index rules;
    })
  config.ai.internal.agentsMd;
  generatedRendered =
    lib.filterAttrs (
      filename: _text: config.ai.internal.agentsMd.${filename}.hasContent
    )
    allRendered;
  sizeAssertions = lib.mapAttrsToList (filename: value:
    aiCommon.sizeAssertion {
      entry = config.ai.internal.files.${filename} or null;
      inherit (value) maxBytes;
      message = size: ''
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
  # The key a runtime's devenv factory writes, as it declares it. Not
  # `context.filename`: Kimchi's names its Home Manager harness file while its
  # devenv factory always writes AGENTS.md.
  sharedTarget = runtime: path:
    isDevenv
    && (config.ai.internal.agentsMdTargets.${runtime} or null) == path
    && builtins.hasAttr path config.ai.internal.agentsMd;
  isAggregate = path: isDevenv && builtins.hasAttr path config.ai.internal.agentsMd;
  # The aggregate's method, and what a public claim on it resolves to: the
  # read-only copy unless the entry names another.
  aggregateMethod = _: "copy-ro";
  # Carried by EVERY definition of a shared target, generated or projected
  # from a runtime's public entry, so whichever one wins still names the
  # writer, its ledger and the consumer fact that makes it a copy. A sibling
  # definition cannot add them: the generated body is a whole-entry default
  # that any ordinary definition discards.
  ownership = {
    entry = writer;
    facts.symlinkReadable = false;
    inherit ledger;
  };
  # Only what can differ for a whole shared file crosses: its bytes and how it
  # lands. The runtime entry's other fields (its own writer, facts, sink) name
  # that runtime's delivery, not the aggregate's.
  projectEntry = entry:
    ownership
    // lib.optionalAttrs (entry.method != null) {inherit (entry) method;}
    // lib.optionalAttrs (entry.mode != null) {inherit (entry) mode;}
    // {
      # `enable` is forwarded only where the runtime entry defines it: a
      # restated default `false` would read as a deliberate disable here and
      # suppress a `run` or `value` entry.
      content =
        lib.optionalAttrs entry.content._enableDefined {inherit (entry.content) enable;}
        // lib.optionalAttrs entry.content.enable (aiTypes.textSourceFile entry.content)
        // lib.optionalAttrs (entry.content.run != null) {inherit (entry.content) run;}
        // lib.optionalAttrs (entry.content.value != null) {inherit (entry.content) value;};
    };
  claims = lib.concatMap (runtime: let
    cfg = config.ai.${runtime};
  in
    lib.optionals cfg.enable (lib.mapAttrsToList (path: entry: {
      inherit entry path runtime;
      method = deliveryMethod.resolve {
        inherit backend entry path;
        methodFor =
          if isAggregate path
          then aggregateMethod
          else cfg.methodFor;
      };
    }) (lib.filterAttrs (_path: runtimeFiles.isLive) cfg.files)))
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
  # when no second runtime supplies a public override. The owner writes a
  # whole file, as a copy or a link; a method it cannot honor would lie about
  # delivery.
  aggregateAssertions = map (claim: {
    assertion = sharedTarget claim.runtime claim.path && builtins.elem claim.method ["copy-ro" "symlink"];
    message = "ai.${claim.runtime}.files.\"${claim.path}\": the shared AGENTS.md aggregate requires a matching context target and a whole-file method (copy-ro or symlink).";
  }) (lib.filter (claim: isAggregate claim.path) claims);
  sharedOverrideDefinitions = map (runtime: let
    inherit (config.ai.${runtime}) enable files;
  in
    lib.mkIf enable {
      ai.internal.files =
        lib.filterAttrs (
          filename: _entry: sharedTarget runtime filename
        )
        (lib.mapAttrs (_filename: projectEntry) files);
    })
  runtimeNames;
in {
  options.ai.internal = {
    agentsMd = lib.mkOption {
      type = lib.types.attrsOf fileType;
      default = {};
      internal = true;
      visible = false;
      description = "Repository-local keyed AGENTS.md compositions shared across runtimes.";
    };
    agentsMdTargets = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      internal = true;
      visible = false;
      description = ''
        Runtime name to the `ai.internal.agentsMd` key its devenv factory
        writes, declared whether or not that key has content. Observers read it
        instead of inferring the key from a runtime option.
      '';
    };
    _ownPlans = deliveryOptions.ownPlansOption;
    activation = lib.mkOption {
      type = deliveryOptions.writerMapType;
      default = {};
      internal = true;
      visible = false;
      description = "The writer that materializes the shared AGENTS.md targets on devenv.";
    };
    files = lib.mkOption {
      type = deliveryOptions.fileMapType;
      default = {};
      apply = runtimeFiles.validateFiles "internal";
      internal = true;
      visible = false;
      description = "Single-owner repository files rendered from cross-runtime compositions.";
    };
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
          # Whole-entry priority keeps the rendered-body test lazy. A public
          # replacement or disable can discard this definition before a
          # store-backed body is read; a sibling-only override is diagnosed as an
          # empty entry and must restate content.
          ai.internal.files = lib.mapAttrs (_filename: text:
            lib.mkDefault (ownership
              // {
                content = {
                  enable = text != "";
                  inherit text;
                };
              }))
          generatedRendered;
        })
        # Declared whether or not any key has content, so the writer that
        # wrote AGENTS.md is still there to retract it when nothing does.
        {
          ai.internal.activation.${writer} = {
            entry = "ai:agents-md:materialize";
            ledgers.${ledger} = {
              codec = "dir";
              path = ".";
            };
          };
        }
        (adapters.devenv {
          cfg = {
            inherit (config.ai.internal) activation files;
            methodFor = deliveryMethod.byRule;
          };
          inherit config options;
          runtime = "internal";
        })
      ]
      ++ sharedOverrideDefinitions
    )))
  ];
}
