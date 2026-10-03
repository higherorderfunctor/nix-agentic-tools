# cspell:ignore foldr
args @ {
  config,
  lib,
  options,
  pkgs,
  ...
}: let
  delegateRoutingRenames = args.delegateRoutingRenames or (import ../lib/when-to-delegate-renames.nix);
  # Kimchi has no delegate primitive; Copilot's sizing controls are not established.
  supportedRuntimes = ["claude" "codex" "kiro"];
  defaults = pkgs.delegate-routing-content;
  portable = config.ai.programs.delegate-routing;
  vocabulary = import ../lib/vocabulary.nix;
  inherit (vocabulary) delegateKinds;
  tierNames = vocabulary.tiers;
  techniqueType = import ../lib/technique-type.nix {inherit lib;};
  familyFunctions = import ../lib/select-families.nix {inherit lib;};
  inherit (familyFunctions) select;
  aiTypes = import ../../../lib/ai/types.nix {inherit lib;};
  enabled = runtime:
    config.ai.${runtime}.programs.delegate-routing.enable
    or null;
  # Mirror program.nix's B4 resolveOverride: null inherits the portable value; keep in sync.
  programEnabled = runtime:
    if enabled runtime == null
    then config.ai.programs.delegate-routing.enable
    else enabled runtime;
  runtimeEnabled = runtime: lib.attrByPath ["ai" runtime "enable"] false config;
  models = lib.genAttrs supportedRuntimes (runtime: config.ai.${runtime}.programs.delegate-routing.models);
  techniques = lib.genAttrs supportedRuntimes (runtime: config.ai.${runtime}.programs.delegate-routing.techniques);
  flattenedFamilies = familyFunctions.flatten portable.families;
  vendors = lib.unique (map (family: family.vendor) flattenedFamilies);
  names = lib.unique (map (family: family.name) flattenedFamilies);
  tiers = lib.unique (map (family: family.tier) flattenedFamilies);
  whenToDelegateOptions = import ../lib/when-to-delegate.nix {
    inherit lib;
    renames = delegateRoutingRenames;
  };
  inherit (whenToDelegateOptions) mkPreset;
  whenToDelegate = config.ai.programs.delegate-routing.whenToDelegate;
  warningMessages = whenToDelegateOptions.warnings whenToDelegate;
  emitWarnings = value:
    lib.foldr (warning: result: lib.warn warning result) value warningMessages;

  # Declare runtime-only controls alongside the factory's enable override.
  runtimeOptions = runtime: {
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
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "Family names to select.";
          };
          tiers = lib.mkOption {
            type = lib.types.listOf (lib.types.enum tierNames);
            default = [];
            description = "Capability tiers to select.";
          };
          vendors = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "Vendors to select.";
          };
        };
      });
      default = defaults.models.${runtime};
      description = "Alternative family selectors. Each non-empty field must match; an empty selector is invalid. Kiro requires an explicit selection when its skill is enabled.";
    };
    techniques = lib.mkOption {
      type = lib.types.attrsOf techniqueType;
      default = {};
      description = "Structured delegation, model inspection and usage techniques.";
    };
  };
in {
  options.ai =
    lib.genAttrs supportedRuntimes (runtime: {
      # This merges with lib/ai/program.nix's override submodule only because it
      # declares no default, description or example; adding any throws "already declared".
      programs.delegate-routing = lib.mkOption {
        type = lib.types.submodule {options = runtimeOptions runtime;};
      };
    })
    // {
      programs.delegate-routing = {
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
        procedure = lib.mkOption {
          type = aiTypes.optionalTextSource {
            defaultContent.text = defaults.procedure;
            description = "delegate routing procedure";
            enableDefault = true;
          };
          default = {};
          description = "Procedure at the end of the skill. Replace with text or source, or disable it.";
        };
        rules = lib.mkOption {
          type = aiTypes.optionalTextSource {
            defaultContent.text = defaults.rules;
            description = "delegate sizing rules";
            enableDefault = true;
          };
          default = {};
          description = "Rules at the top of the skill. Replace with text or source, or disable them.";
        };
        whenToDelegate = lib.mkOption {
          inherit (whenToDelegateOptions) type;
          default = {};
          apply = whenToDelegateOptions.rename;
          description = "Always-on guidance describing when to delegate work.";
        };
      };
    };

  # Emit one portable enable option and skills/rules for each supported runtime.
  imports = [
    (import ../../../lib/ai/mkSkillPackageModule.nix {
      name = "delegate-routing";
      enableDescription = "delegate model and effort sizing skills and rule";
      inherit supportedRuntimes;
      skills = {
        pkgs,
        runtime,
        ...
      }: {
        delegate-routing = "${pkgs.delegate-routing-content.passthru.mkSkill {
          inherit runtime models techniques;
          inherit (portable) families;
          rules = lib.optionalString portable.rules.enable portable.rules.text;
          procedure = lib.optionalString portable.procedure.enable portable.procedure.text;
          inherit (config.ai.${runtime}.programs.delegate-routing) extraRuntimes manualExternalDelegates;
        }}";
      };
      rules = _:
        import ../router.nix {
          inherit lib;
          entries = config.ai.programs.delegate-routing.whenToDelegate;
        };
    })
  ];

  config =
    {
      ai = lib.mkMerge [
        {
          programs.delegate-routing = {
            families = lib.mapAttrsRecursive (_: lib.mkDefault) defaults.families;
            whenToDelegate = {
              "Launch independent work together" = mkPreset {source = ../fragments/launch-independent-work-together.md;};
              "Orchestrator session" = mkPreset {source = ../fragments/orchestrator-session.md;};
              "Prefer the flat-rate pool" = mkPreset {source = ../fragments/prefer-the-flat-rate-pool.md;};
              "Verify by the artifact" = mkPreset {source = ../fragments/verify-by-the-artifact.md;};
            };
          };
        }
        (lib.genAttrs supportedRuntimes (runtime: {
          programs.delegate-routing.techniques = lib.mapAttrsRecursive (_: lib.mkDefault) defaults.techniques.${runtime};
        }))
      ];
      assertions =
        (
          if options ? warnings
          then lib.id
          else emitWarnings
        )
        (
          # Static validation is ungated on purpose; runtime-dependent checks apply only when the source runtime and program are enabled.
          lib.concatMap (runtime: let
            path = "ai.${runtime}.programs.delegate-routing";
            sourceEnabled = programEnabled runtime && runtimeEnabled runtime;
            extraRuntimes = config.ai.${runtime}.programs.delegate-routing.extraRuntimes;
            manualExternalDelegates = config.ai.${runtime}.programs.delegate-routing.manualExternalDelegates;
            requiredTargets = lib.unique ([runtime] ++ extraRuntimes ++ manualExternalDelegates);
          in
            map (target: {
              assertion = !sourceEnabled || runtimeEnabled target;
              message = "${path}.extraRuntimes includes `${target}`, but ai.${target}.enable is false. Enable that runtime or use manualExternalDelegates.";
            })
            (lib.subtractLists manualExternalDelegates extraRuntimes)
            ++ map (target: {
              assertion = !sourceEnabled || select portable.families models.${target} != [];
              message = "ai.${target}.programs.delegate-routing.models must select at least one configured family when its program and runtime are enabled or an enabled runtime references it.";
            })
            requiredTargets
            ++ lib.concatMap (selector: let
              unknown =
                lib.subtractLists vendors selector.vendors
                ++ lib.subtractLists tiers selector.tiers
                ++ lib.subtractLists names selector.families;
            in [
              {
                assertion = selector.vendors != [] || selector.tiers != [] || selector.families != [];
                message = "${path}.models contains an empty selector; specify vendors, tiers or families.";
              }
              {
                assertion = unknown == [];
                message = "${path}.models references unknown values ${builtins.toJSON unknown} absent from ai.programs.delegate-routing.families.";
              }
            ])
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
          supportedRuntimes
        );
    }
    // lib.optionalAttrs (options ? warnings) {
      warnings = warningMessages;
    };
}
