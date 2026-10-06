# Shared by both backends. `hookRuntimes` names the runtimes whose
# UserPromptSubmit hook this backend can deliver: Kimchi reads lifecycle hooks
# only from a trusted project's `.kimchi/hooks.json`, so Home Manager has no
# file to put its reminder in.
{hookRuntimes}: {
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
  reminder = import ../lib/reminder.nix {inherit lib pkgs;};
  resolved = runtime: let
    local = portable.runtimes.${runtime};
  in {
    routing = entries.resolveRouting portable.routing local.routing;
    workflows = entries.resolveWorkflows portable.workflows local.workflows;
  };
  inherit (import ../../../lib/ai/ai-common.nix {inherit lib;}) resolveOverride;
  programEnabled = runtime:
    resolveOverride {
      topValue = portable.enable;
      cliValue = portable.runtimes.${runtime}.enable;
    };
  runtimeEnabled = runtime: lib.attrByPath ["ai" runtime "enable"] false config;
  sourceEnabled = runtime: programEnabled runtime && runtimeEnabled runtime;
  # The skill's Kiro evidence covers the v3 engine only. Default v3 on only
  # when ai.kiro.package != null: the managed wrapper carries --v3 to launches.
  reachesKiro = lib.any (runtime:
    sourceEnabled runtime
    && builtins.elem "kiro" ([runtime] ++ portable.runtimes.${runtime}.extraRuntimes ++ portable.runtimes.${runtime}.manualExternalDelegates))
  supportedRuntimes;
  kiroV3Declared = lib.hasAttrByPath ["ai" "kiro" "v3"] options;
  reminderEnabled = runtime:
    resolveOverride {
      topValue = portable.reminder.enable;
      cliValue = portable.runtimes.${runtime}.reminder.enable;
    };
  # Kiro's extraSystemPrompt reaches typed agents only, never its built-in
  # default agent, so Kiro keeps the always-on entries as an always-on rule.
  ruleRuntimes = ["kiro"];
  # The always-on entries for one runtime, or null when none is enabled.
  alwaysText = runtime:
    import ../router.nix {
      inherit lib;
      entries = (resolved runtime).routing;
      inherit (resolved runtime) workflows;
    };
  # Per-runtime writes need that runtime's module in this evaluation.
  present = pool: lib.filter (runtime: lib.hasAttrByPath ["ai" runtime pool] options);
  reminderHookEnabled = runtime: programEnabled runtime && reminderEnabled runtime;
  reminderRuntimes = present "hooks" hookRuntimes;
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
      reminder.enable = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Whether this runtime receives the per-turn reminder. null inherits `ai.programs.delegate-routing.reminder.enable`.";
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
          description = "the per-turn reminder injected as user-side context";
          enableDefault = true;
        };
        default = {};
        defaultText = lib.literalExpression (lib.generators.toPretty {} {
          enable = true;
          text = reminder.defaultText;
        });
        description = ''
          A short standing request, in the user's voice, injected on every turn by a
          `UserPromptSubmit` hook as `additionalContext`: Claude, Codex and Kiro on
          both backends, Kimchi on devenv only (Home Manager has no Kimchi hook
          file). Disable it per runtime with `runtimes.<runtime>.reminder.enable`.

          The default asks the model to load the delegate-routing skill and follow
          its always-on guidance, and grants permission for subagents, workflows and
          deep research. That grant satisfies the "unless the user requested it"
          clause of Claude Code's `heron_brook` delegation clamp, which a
          system-attributed channel was measured not to do; see
          `packages/claude-code/docs/heron-brook-clamp.md` before rewording it.
          It is cumulative context: one line per turn.

          Enabling the program enables the reminder. On Codex it is a definition
          of `ai.codex.hooks`, which cannot be combined with inline hooks in
          `ai.codex.native.settings.hooks`: move those to `ai.codex.hooks`, or set
          `runtimes.codex.reminder.enable = false`.
        '';
      };
      runtimes = lib.genAttrs supportedRuntimes runtimeOptions;
    };

  # Emit one portable enable option, a skill for each supported runtime and
  # Kiro's always-on rule.
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
      rules = {runtime, ...}: let
        text = alwaysText runtime;
      in
        lib.optionalAttrs (builtins.elem runtime ruleRuntimes && text != null) {
          delegate-routing-router = {
            description = "Load delegate-routing before delegating work";
            inherit text;
          };
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
      # ai.kiro.v3 to set.
      (lib.optionalAttrs kiroV3Declared {
        kiro.v3 = lib.mkIf (reachesKiro && config.ai.kiro.package != null) (lib.mkDefault true);
      })
      # Always-on entries reach the other runtimes' own system prompts.
      (lib.genAttrs (present "extraSystemPrompt" (lib.subtractLists ruleRuntimes supportedRuntimes)) (runtime: let
        text = alwaysText runtime;
      in
        lib.mkIf (programEnabled runtime && text != null) {
          extraSystemPrompt.delegate-routing = lib.mapAttrs (_: lib.mkDefault) {
            enable = true;
            inherit text;
          };
        }))
      (lib.genAttrs reminderRuntimes (runtime:
        lib.mkIf (reminderHookEnabled runtime)
        (reminder.hooks.${runtime} portable.reminder.text)))
    ];
    warnings = lib.optional (kiroV3Declared && reachesKiro && !config.ai.kiro.v3) ''
      ai.programs.delegate-routing reaches Kiro, but ai.kiro.v3 is false. The
      skill's Kiro behavior is verified on the v3 engine only; sessions on
      another engine may not delegate as the skill describes.
    '';
    assertions =
      [
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
            message = "${path}.${list} includes `${target}`, but ai.${target}.enable is false. Enable it with ai.${target}.enable = true.";
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
