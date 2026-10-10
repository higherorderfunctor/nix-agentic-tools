{backend}: {
  config,
  lib,
  options,
  pkgs,
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
  inherit (familyFunctions) select;
  entryDefaults = import ../lib/entries.nix {inherit lib;};
  entryTypes = import ../lib/entry-type.nix {inherit lib;};
  entries = import ../lib/resolve-entries.nix {inherit lib;};
  entryOptions = entryTypes.options;
  aiTypes = import ../../../lib/ai/types.nix {inherit lib;};
  optionPaths = import ../../../lib/ai/option-paths.nix {inherit lib pkgs;};
  reminder = import ../lib/reminder.nix {inherit lib pkgs;};
  # Home Manager has no Kimchi hook file.
  hookRuntimes = ["claude" "codex" "kiro"] ++ lib.optional (backend == "devenv") "kimchi";
  reminderProgram = (import ../../../lib/ai/program.nix {inherit lib;}).mkProgram {
    name = "delegate-routing";
    inherit supportedRuntimes;
    options.reminder.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to deliver the per-turn delegation reminder.";
    };
  };
  reminderEnabled = runtime: (reminderProgram.resolve config runtime).reminder.enable;
  reminderRuntimes = lib.filter (runtime: lib.hasAttrByPath ["ai" runtime "hooks"] options) hookRuntimes;
  reminderHookEnabled = runtime: sourceEnabled runtime && reminderEnabled runtime;
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
  sourceEnabled = runtime: programEnabled runtime && runtimeEnabled runtime;
  # The skill's Kiro evidence covers the v3 engine only. Default v3 on only
  # when ai.kiro.cli.package != null: the managed wrapper carries --v3 to launches.
  reachesKiro = lib.any (runtime:
    sourceEnabled runtime
    && builtins.elem "kiro" ([runtime] ++ portable.runtimes.${runtime}.extraRuntimes ++ portable.runtimes.${runtime}.manualExternalDelegates))
  supportedRuntimes;
  kiroV3Declared = lib.hasAttrByPath ["ai" "kiro" "cli" "v3"] options;
  models = lib.genAttrs supportedRuntimes (runtime: config.ai.programs.delegate-routing.runtimes.${runtime}.models);
  techniques = familyFunctions.effectiveTechniques config;
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
        description = "Describe external delegates for explicit user requests only; never auto-select them. Each named runtime must be enabled through ai.<runtime>.enable. Manual-only takes precedence over extraRuntimes.";
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
      reminder = lib.mkOption {
        type = aiTypes.optionalTextSource {
          defaultContent.text = reminder.defaultText;
          description = "the per-turn delegate-routing reminder";
          enableDefault = true;
        };
        default = {};
        description = ''
          Per-turn UserPromptSubmit reminder in the user's voice. Claude and Codex
          receive JSON additionalContext on both backends; Kimchi on devenv only.
          Kiro receives plain text on both. Set runtimes.<runtime>.reminder.enable
          to false to withhold it from that runtime.
        '';
      };

      runtimes =
        lib.genAttrs supportedRuntimes (runtime:
          runtimeOptions runtime // reminderProgram.module.options.ai.programs.delegate-routing.runtimes.${runtime});
    };

  # Emit one portable enable option and skills/rules for each supported runtime.
  imports = [
    (import ../../../lib/ai/mkSkillPackageModule.nix {
      name = "delegate-routing";
      enableDescription = "delegate model and effort sizing skills and rule";
      inherit backend supportedRuntimes;
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
      # Guarded on the declaration: a consumer without the Kiro module has no
      # ai.kiro.cli.v3 to set.
      (lib.optionalAttrs kiroV3Declared {
        kiro.cli = lib.mkIf (reachesKiro && config.ai.kiro.cli.package != null) {
          tweaks = lib.mkIf config.ai.kiro.cli.workflows.enable {
            relativeFileCheckPaths = lib.mkDefault true;
            stripVendorWorktreeSteering = lib.mkDefault true;
          };
          v3 = lib.mkDefault true;
        };
      })
      (lib.genAttrs reminderRuntimes (runtime:
        lib.mkIf (reminderHookEnabled runtime)
        (reminder.hooks.${runtime} portable.reminder.text)))
    ];
    warnings =
      map (runtime: "ai.programs.delegate-routing.runtimes.${runtime}.reminder.enable is true, but this backend cannot deliver a reminder hook for ${runtime}. Disable that runtime reminder or use devenv.")
      (lib.filter (runtime: sourceEnabled runtime && portable.runtimes.${runtime}.reminder.enable == true && !(builtins.elem runtime hookRuntimes)) supportedRuntimes)
      ++ lib.optional (kiroV3Declared && reachesKiro && !config.ai.kiro.cli.v3) ''
        ai.programs.delegate-routing reaches Kiro, but ai.kiro.cli.v3 is false. The
        skill's Kiro behavior is verified on the v3 engine only; sessions on
        another engine may not delegate as the skill describes.
      '';
    assertions =
      [
        {
          assertion = !(builtins.elem "kiro" reminderRuntimes && reminderHookEnabled "kiro") || config.ai.kiro.hooksDir == null;
          message = "ai.programs.delegate-routing: the Kiro reminder cannot coexist with ai.kiro.hooksDir. Set runtimes.kiro.reminder.enable = false or move those hooks out of hooksDir.";
        }
        {
          assertion = !lib.any reminderHookEnabled reminderRuntimes || portable.reminder._sourceWins || portable.reminder.text != "";
          message = "ai.programs.delegate-routing.reminder.text must be non-empty when a runtime reminder hook is enabled, unless a source supplies the content.";
        }
        {
          assertion = lib.allUnique (map (family: family.name) flattenedFamilies);
          message = "ai.programs.delegate-routing.families: family names must be unique across vendors.";
        }
      ]
      ++ lib.concatMap (runtime: let
        path = "ai.programs.delegate-routing.runtimes.${runtime}";
        extraRuntimes = config.ai.programs.delegate-routing.runtimes.${runtime}.extraRuntimes;
        manualExternalDelegates = config.ai.programs.delegate-routing.runtimes.${runtime}.manualExternalDelegates;
        requiredTargets = lib.unique ([runtime] ++ extraRuntimes ++ manualExternalDelegates);
      in
        lib.concatMap (list:
          map (target: {
            assertion = !(sourceEnabled runtime) || runtimeEnabled target;
            message = "${path}.${list} includes `${target}`, but ai.${target}.enable is false. Enable it with ${lib.concatStringsSep "." (optionPaths.launcher target "enable")} = true.";
          })
          portable.runtimes.${runtime}.${list}) ["extraRuntimes" "manualExternalDelegates"]
        ++ map (target: {
          assertion = !(sourceEnabled runtime) || select portable.families models.${target} != [];
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
