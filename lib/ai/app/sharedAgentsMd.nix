# One keyed composer for every repository-local AGENTS.md target shared by
# AGENTS.md-standard runtimes. Runtime factories contribute named context/rule
# units; this module renders each filename once after the module system has
# deduplicated equal definitions and rejected divergent definitions for a key.
#
# The composer is the layer-1 owner `internal`: the composition becomes its
# staged entry (`ai.internal._generatedFiles`), is formatted and byte-checked in
# its one tree, and reaches `ai.files` as the single claim on the path. The
# result is a read-only copy by default, not a store symlink: a committed
# AGENTS.md that links into /nix/store dangles on every other machine and on
# github.com. A runtime's own `files` entry for the path forwards unclaimed
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
  # The guards' programs come from this flake's tree, not the raw pkgs.
  generatedFiles = import ./generatedFiles.nix {
    inherit lib;
    pkgs = pkgs // {ai = config.ai.internal.packages;};
  };
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
          "The option `${lib.showOption loc}` has divergent contributions; AGENTS.md units with the same key must have identical payloads";
    };
  deduplicatedLines = deduplicatingType {
    name = "deduplicated Markdown text";
    check = builtins.isString;
  };
  deduplicatedNullableLines = deduplicatingType {
    name = "null or deduplicated Markdown text";
    check = value: value == null || builtins.isString value;
  };
  deduplicatedIndexEntry = deduplicatingType {
    name = "deduplicated rule index entry";
    check = value:
      builtins.isAttrs value
      && builtins.isString value.description
      && builtins.elem value.inclusion ["auto" "fileMatch" "manual"]
      && (value.matcher == null || (builtins.isList value.matcher && lib.all builtins.isString value.matcher))
      && builtins.isList value.references
      && lib.all builtins.isString value.references;
  };
  fileType = lib.types.submodule {
    options = {
      audiences = lib.mkOption {
        type = lib.types.attrsOf (lib.types.listOf lib.types.str);
        default = {};
        apply = lib.mapAttrs (_: names: lib.sort builtins.lessThan (lib.unique names));
        internal = true;
        visible = false;
        description = "Contributing runtimes for each rule or index key; audience guidance is advisory, not file isolation.";
      };
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
        type = lib.types.attrsOf deduplicatedIndexEntry;
        default = {};
        internal = true;
        visible = false;
        description = "Resolved rule index metadata keyed by stable rule identity.";
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
  tiers = lib.mapAttrs (filename: value:
    agentsmd.tierIndex {
      inherit filename;
      inherit (value) audiences hasOnDemandIndex index;
    })
  config.ai.internal.agentsMd;
  allRendered = lib.mapAttrs (filename: value:
    agentsmd.renderKeyed {
      inherit (value) audiences context hasOnDemandIndex rules;
      inherit (tiers.${filename}) index indexGroups;
    })
  config.ai.internal.agentsMd;
  generatedRendered =
    lib.filterAttrs (
      filename: _text: config.ai.internal.agentsMd.${filename}.hasContent
    )
    allRendered;
  children = lib.foldl' (result: filename: let
    additions = lib.mapAttrs (_path: text: {inherit filename text;}) tiers.${filename}.children;
    collisions = lib.attrNames (builtins.intersectAttrs additions (result // config.ai.internal.agentsMd));
  in
    if collisions != []
    then throw "AGENTS.md child index path collides with another target: ${lib.concatStringsSep ", " collisions}"
    else result // additions) {} (lib.attrNames config.ai.internal.agentsMd);
  # Each target's hard limit, measured on the built file whoever supplies it.
  limits =
    lib.mapAttrs (_filename: value: {
      bytes = value.maxBytes;
      hint = "Trim the contributing context or rules, replace the final file, or raise the runtime's document-size limit.";
    })
    (lib.filterAttrs (_filename: value: value.maxBytes != null) config.ai.internal.agentsMd);
  staged = config.ai.internal._generatedFiles;
  tree = generatedFiles.tree {
    backend = "devenv";
    checks = lib.genAttrs generatedFiles.surfaces (surface: config.ai.checks.${surface});
    inherit config;
    entries = generatedFiles.treeEntries {
      inherit (config.ai) files;
      inherit staged;
    };
    maxBytes = limits;
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
    _generatedTree = generatedFiles.generatedTreeOption;
    # The helper declares the composer's layer-1 options; they stay out of the
    # option reference like the rest of `ai.internal`.
    activation = lib.mkOption {visible = false;};
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
    files = lib.mkOption {visible = false;};
    services = lib.mkOption {visible = false;};
  };

  config = lib.mkMerge [
    (lib.optionalAttrs isDevenv {
      ai.internal = {
        _generatedFiles =
          lib.mapAttrs (filename: text: {
            content = {inherit text;};
            format = "markdown";
            method = "ro";
            surface =
              if config.ai.internal.agentsMd.${filename}.context != null
              then "context"
              else "rules";
          })
          generatedRendered
          // lib.mapAttrs (_path: child: {
            content.text = child.text;
            format = "markdown";
            method = "ro";
            surface = "rules";
          })
          children;
        _generatedTree = tree;
        files = lib.mkMerge [
          (generatedFiles.layer1 {inherit staged tree;})
          # Keep names structural: gating staged children on final root files
          # would make ai.files' attribute discovery depend on itself. Final
          # enable arbitration also keeps discarded child bytes out of the tree.
          (lib.mapAttrs (_path: child: {
              enable = lib.mkDefault (
                config.ai.files.${child.filename}.enable
                && config.ai.files.${child.filename}._contentPrio >= (lib.mkDefault null).priority
              );
            })
            children)
          # Every shared target is the composer's claim, so a runtime's
          # entry alone still lands as a read-only copy, and only when some
          # definition supplies content. Read by priority, so the content
          # (and the tree it points into) stays unevaluated.
          (lib.mapAttrs (filename: _: {
              enable = lib.mkDefault (
                if config.ai.files.${filename}._contentPrio < (lib.mkDefault null).priority
                then true
                else if generatedRendered ? ${filename}
                then generatedRendered.${filename} != ""
                else config.ai.files.${filename}._contentPrio < (lib.mkOptionDefault null).priority
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
    })
  ];
}
