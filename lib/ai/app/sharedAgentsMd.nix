# One keyed composer for every repository-local AGENTS.md target shared by
# AGENTS.md-standard runtimes. Runtime factories contribute named context/rule
# units; this module renders each filename once after the module system has
# deduplicated equal definitions and rejected divergent definitions for a key.
# Applicable public final-file entries from enabled runtimes still on the old
# path arbitrate here too, so replacement and tombstones cannot bypass the one
# owner or their runtime's sole enable gate.
#
# The composer is the layer-1 owner `internal`: the arbitrated file becomes its
# staged entry (`ai.internal._generatedFiles`), is formatted and byte-checked in
# its one tree, and reaches `ai.files2` as the single claim on the path. The
# result is a read-only copy by default, not a store symlink: a committed
# AGENTS.md that links into /nix/store dangles on every other machine and on
# github.com. A runtime's own `files2` entry for the path forwards unclaimed
# and arbitrates by module priority. An entry that states its own `method`
# keeps it.
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
  aiTypes = import ../types.nix {inherit lib;};
  deliveryMethod = import ../deliveryMethod.nix {inherit lib;};
  deliveryOptions = import ../delivery-options.nix {inherit lib;};
  # The guards' programs come from this flake's tree, not the raw pkgs.
  generatedFiles = import ./generatedFiles.nix {
    inherit lib;
    pkgs = pkgs // {ai = config.ai.internal.packages;};
  };
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
      hasOnDemandIndex = lib.mkOption {
        type = lib.types.bool;
        default = false;
        internal = true;
        visible = false;
        description = "Whether the index includes a model-selected or manual trigger.";
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
      inherit (value) context hasOnDemandIndex index rules;
    })
  config.ai.internal.agentsMd;
  generatedRendered =
    lib.filterAttrs (
      filename: _text: config.ai.internal.agentsMd.${filename}.hasContent
    )
    allRendered;
  # Each target's hard limit, measured on the built file whoever supplies it.
  limits =
    lib.mapAttrs (_filename: value: {
      bytes = value.maxBytes;
      hint = "Trim the contributing context or rules, replace the final file, or raise the runtime's document-size limit.";
    })
    (lib.filterAttrs (_filename: value: value.maxBytes != null) config.ai.internal.agentsMd);
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
  # Only what can differ for a whole shared file crosses: its bytes and how it
  # lands. The runtime entry's other fields (its own writer and facts) name
  # that runtime's delivery, not the aggregate's.
  projectEntry = entry:
    lib.optionalAttrs (entry.method != null) {inherit (entry) method;}
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
    }
    # The entry's own format, stated or not: a replacement is Markdown only
    # when it says so, exactly as Codex's AGENTS.md on Home Manager, where a
    # consumer definition discards the whole generated entry, `format` with
    # it. Only the generated aggregate below states `markdown` itself.
    // {inherit (entry) format;};
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
  # Transitional until the old path is deleted, which leaves the composer
  # staging its composition directly: the arbitrated file as the composer's
  # staged entry, the old method names mapped onto the engine's.
  methods = {
    copy-ro = "ro";
    shared = "rw";
    symlink = "symlink";
  };
  stage = entry: {
    content =
      lib.optionalAttrs entry.content.enable (aiTypes.textSourceFile entry.content)
      // lib.optionalAttrs (entry.content.run != null) {inherit (entry.content) run;}
      // lib.optionalAttrs (entry.content.value != null) {inherit (entry.content) value;};
    inherit (entry) format mode;
    method =
      if entry.method == null
      then "ro"
      else methods.${entry.method};
    surface = entry.content._surface;
  };
  staged = config.ai.internal._generatedFiles;
  tree = generatedFiles.tree {
    backend = "devenv";
    checks = lib.genAttrs deliveryOptions.surfaces (surface: config.ai.checks.${surface});
    inherit config;
    entries = generatedFiles.treeEntries {
      inherit (config.ai) files2;
      inherit staged;
    };
    maxBytes = config.ai.internal._maxBytes;
    runtime = "internal";
  };
in {
  imports = [
    (import ../../../packages/ai-module/lib/runtime.nix {
      enabled = true;
      name = "internal";
    })
  ];

  options.ai.internal = {
    _generatedFiles = generatedFiles.stagedOption;
    _generatedTree = deliveryOptions.generatedTreeOption;
    _maxBytes = deliveryOptions.maxBytesOption;
    # The helper declares the composer's layer-1 options; they stay out of the
    # option reference like the rest of `ai.internal`.
    activation2 = lib.mkOption {visible = false;};
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
    files = lib.mkOption {
      type = deliveryOptions.fileMapType;
      default = {};
      internal = true;
      visible = false;
      description = "Single-owner repository files rendered from cross-runtime compositions.";
    };
    files2 = lib.mkOption {visible = false;};
  };

  config = lib.mkMerge [
    (lib.optionalAttrs (options ? assertions) {
      assertions = collisionAssertions ++ methodAssertions ++ aggregateAssertions;
    })
    (lib.optionalAttrs isDevenv (lib.mkMerge (
      [
        {
          ai.internal = {
            # Keep keys structural: checking old content here would read a
            # source before a layer-1 replacement or disable can discard it.
            _generatedFiles = lib.mapAttrs (_filename: stage) config.ai.internal.files;
            _generatedTree = tree;
            _maxBytes = limits;
            files2 = lib.mkMerge [
              (generatedFiles.layer1 {inherit staged tree;})
              # Every shared target is the composer's claim, so a runtime's
              # entry alone still lands as a read-only copy, and only when some
              # definition supplies content. Read by priority, so the content
              # (and the tree it points into) stays unevaluated.
              (lib.mapAttrs (filename: _: {
                  enable = lib.mkDefault (
                    if config.ai.files2.${filename}._contentPrio < (lib.mkDefault null).priority
                    then true
                    else if config.ai.internal.files ? ${filename}
                    then runtimeFiles.isLive config.ai.internal.files.${filename}
                    else config.ai.files2.${filename}._contentPrio < (lib.mkOptionDefault null).priority
                  );
                  method = lib.mkIf (!staged ? ${filename}) (lib.mkDefault "ro");
                })
                config.ai.internal.agentsMd)
            ];
            # The old writer's ledger, declared whether or not any key has
            # content, so a copy it wrote drains when nothing contributes.
            legacyLedgers = [
              {
                codec = "dir";
                ledger = "materialize/agents-md.manifest";
                path = ".";
              }
            ];
          };
        }
        (lib.mkIf (config.ai.internal.agentsMd != {}) {
          # Do not inspect rendered bytes to discover whether a target exists.
          # The separate boolean inventory lets priority arbitration discard this
          # lazy default without forcing source-backed generated content.
          # Whole-entry priority keeps the rendered-body test lazy. A public
          # replacement or disable can discard this definition before a
          # store-backed body is read; a sibling-only override is diagnosed as an
          # empty entry and must restate content.
          ai.internal.files = lib.mapAttrs (_filename: text:
            lib.mkDefault {
              content = {
                _generated = true;
                _surface =
                  if config.ai.internal.agentsMd.${_filename}.context != null
                  then "context"
                  else "rules";
                enable = text != "";
                inherit text;
              };
              format = "markdown";
            })
          generatedRendered;
        })
      ]
      ++ sharedOverrideDefinitions
    )))
  ];
}
