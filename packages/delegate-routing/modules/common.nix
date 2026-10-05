{
  config,
  lib,
  ...
}: let
  # Copilot's sizing controls are not established.
  supportedRuntimes = ["claude" "codex" "kimchi" "kiro"];
  # This flake's build unless the overlay is applied (ai.internal.roots).
  defaults = config.ai.internal.roots.delegate-routing-content;
  portable = config.ai.programs.delegate-routing;
  vocabulary = import ../lib/vocabulary.nix;
  inherit (vocabulary) delegateKinds;
  tierNames = vocabulary.tiers;
  techniqueType = import ../lib/technique-type.nix {inherit lib;};
  familyFunctions = import ../lib/select-families.nix {inherit lib;};
  inherit (familyFunctions) automatic select;
  entryDefaults = import ../lib/entries.nix {inherit lib;};
  entryTypes = import ../lib/entry-type.nix {inherit lib;};
  entries = import ../lib/resolve-entries.nix {inherit lib;};
  entryOptions = entryTypes.options;
  resolved = runtime: let
    local = portable.runtimes.${runtime};
  in {
    routing = entries.resolveRouting portable.routing local.routing;
    workflows = entries.resolveWorkflows portable.workflows local.workflows;
  };
  enabled = runtime:
    config.ai.programs.delegate-routing.runtimes.${runtime}.enable
    or null;
  # Mirror program.nix's B4 resolveOverride: null inherits the portable value; keep in sync.
  programEnabled = runtime:
    if enabled runtime == null
    then config.ai.programs.delegate-routing.enable
    else enabled runtime;
  runtimeEnabled = runtime: lib.attrByPath ["ai" runtime "enable"] false config;
  models = lib.genAttrs supportedRuntimes (runtime: config.ai.programs.delegate-routing.runtimes.${runtime}.models);
  techniques = lib.genAttrs supportedRuntimes (runtime: config.ai.programs.delegate-routing.runtimes.${runtime}.techniques);
  flattenedFamilies = familyFunctions.flatten portable.families;
  vendors = lib.unique (map (family: family.vendor) flattenedFamilies);
  names = lib.unique (map (family: family.name) flattenedFamilies);
  tiers = lib.unique (map (family: family.tier) flattenedFamilies);
  # Runtime maps are package-owned, outside the factory's null-as-inherit controls.
  runtimeOptions = runtime:
    entryOptions
    // {
      extraRuntimes = lib.mkOption {
        type = lib.types.listOf (lib.types.enum (lib.remove runtime supportedRuntimes));
        default = [];
        description = "Auto-selectable external delegate runtimes. Each named runtime must be enabled through ai.<runtime>.enable.";
      };
      manualExternalDelegates = lib.mkOption {
        type = lib.types.listOf (lib.types.enum (lib.remove runtime supportedRuntimes));
        default = [];
        description = "Describe external delegates for explicit user requests only; never auto-select them. No runtime enable is required. Manual-only takes precedence over extraRuntimes.";
      };
      models = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule {
          options = {
            families = lib.mkOption {
              type = lib.types.listOf (lib.types.enum names);
              default = [];
              description = "Family names to select.";
            };
            tiers = lib.mkOption {
              type = lib.types.listOf (lib.types.enum tiers);
              default = [];
              description = "Capability tiers to select.";
            };
            vendors = lib.mkOption {
              type = lib.types.listOf (lib.types.enum vendors);
              default = [];
              description = "Vendors to select.";
            };
          };
        });
        default = defaults.models.${runtime};
        description = "Alternative family selectors. Each non-empty field must match; an empty selector is invalid. Kimchi and Kiro require an explicit selection when their skill is enabled.";
      };
      techniques = lib.mkOption {
        type = lib.types.attrsOf techniqueType;
        default = {};
        description = "Structured delegation, model inspection and usage techniques.";
      };
    };
in {
  options.ai.programs.delegate-routing =
    entryOptions
    // {
      families = lib.mkOption {
        type = lib.types.attrsOf (lib.types.attrsOf (lib.types.submodule {
          options = {
            avoidFor = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Tasks this family should avoid.";
            };
            effort = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Delegate effort guidance.";
            };
            match = lib.mkOption {
              type = lib.types.str;
              description = "Normalized live model id pattern, resolved using the runtime's own spelling.";
            };
            tier = lib.mkOption {
              type = lib.types.enum tierNames;
              description = "Capability tier.";
            };
            useFor = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Tasks suited to this family.";
            };
          };
        }));
        default = {};
        description = "Portable model families keyed by vendor and family name. Override any field or add a family.";
      };
      runtimes = lib.genAttrs supportedRuntimes runtimeOptions;
    };

  # Emit one portable enable option and skills/rules for each supported runtime.
  imports = [
    (import ../../../lib/ai/mkSkillPackageModule.nix {
      name = "delegate-routing";
      enableDescription = "delegate model and effort sizing skills and rule";
      inherit supportedRuntimes;
      skills = {runtime, ...}: {
        delegate-routing = "${defaults.passthru.mkSkill {
          inherit runtime models techniques;
          inherit (portable) families;
          inherit (resolved runtime) routing workflows;
          inherit (config.ai.programs.delegate-routing.runtimes.${runtime}) extraRuntimes manualExternalDelegates;
        }}";
      };
      rules = {runtime, ...}:
        import ../router.nix {
          inherit lib;
          entries = (resolved runtime).routing;
          inherit (resolved runtime) workflows;
        };
    })
  ];

  config = {
    ai = lib.mkMerge [
      {
        programs.delegate-routing = {
          families = lib.mapAttrsRecursive (_: lib.mkDefault) defaults.families;
          routing = lib.mapAttrsRecursive (_: lib.mkDefault) entryDefaults.routing;
          workflows = lib.mapAttrsRecursive (_: lib.mkDefault) entryDefaults.workflows;
        };
      }
      {
        programs.delegate-routing.runtimes = lib.genAttrs supportedRuntimes (runtime: {
          techniques = lib.mapAttrsRecursive (_: lib.mkDefault) defaults.techniques.${runtime};
        });
      }
    ];
    assertions =
      [
        {
          assertion = lib.allUnique (map (family: family.name) flattenedFamilies);
          message = "ai.programs.delegate-routing.families: family names must be unique across vendors.";
        }
      ]
      ++ lib.concatMap (runtime: let
        path = "ai.programs.delegate-routing.runtimes.${runtime}";
        sourceEnabled = programEnabled runtime && runtimeEnabled runtime;
        extraRuntimes = config.ai.programs.delegate-routing.runtimes.${runtime}.extraRuntimes;
        manualExternalDelegates = config.ai.programs.delegate-routing.runtimes.${runtime}.manualExternalDelegates;
        requiredTargets = lib.unique ([runtime] ++ extraRuntimes ++ manualExternalDelegates);
      in
        map (target: {
          assertion = !sourceEnabled || runtimeEnabled target;
          message = "${path}.extraRuntimes includes `${target}`, but ai.${target}.enable is false. Enable that runtime or use manualExternalDelegates.";
        })
        (automatic {inherit runtime extraRuntimes manualExternalDelegates;})
        ++ map (target: {
          assertion = !sourceEnabled || select portable.families models.${target} != [];
          message = "ai.programs.delegate-routing.runtimes.${target}.models must select at least one configured family when its program and runtime are enabled or an enabled runtime references it.";
        })
        requiredTargets
        ++ map (selector: {
          assertion = selector.vendors != [] || selector.tiers != [] || selector.families != [];
          message = "${path}.models contains an empty selector; specify vendors, tiers or families.";
        })
        models.${runtime}
        ++ lib.concatLists (lib.mapAttrsToList (name: node: let
            delegate = builtins.elem node.kind delegateKinds;
            techniquePath = "${path}.techniques.${lib.strings.escapeNixIdentifier name}";
          in [
            {
              assertion = (node.pinsModel != null) == delegate && (node.pinsEffort != null) == delegate;
              message = "${techniquePath}: pinsModel and pinsEffort must be non-null exactly for workflow, subagent and external techniques.";
            }
            {
              assertion = node.kind != "external" || node.command != null;
              message = "${techniquePath}.command is required for an external technique.";
            }
          ])
          techniques.${runtime}))
      supportedRuntimes;
  };
}
