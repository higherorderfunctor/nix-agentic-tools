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
  tiers = ["frontier" "strong" "mid" "small"];
  select = import ../lib/select-families.nix {inherit lib;};
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
  present = builtins.filter (runtime: lib.hasAttrByPath ["ai" runtime "skills"] options) supportedRuntimes;
  models = lib.genAttrs supportedRuntimes (runtime: config.ai.${runtime}.programs.delegate-routing.models);
  techniques = lib.genAttrs supportedRuntimes (runtime: config.ai.${runtime}.programs.delegate-routing.techniques);
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
            type = lib.types.listOf (lib.types.enum tiers);
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
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          command = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Launch or inspection command; required for external delegates.";
          };
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether to render this technique.";
          };
          kind = lib.mkOption {
            type = lib.types.enum ["workflow" "subagent" "external" "introspect" "usage"];
            description = "The technique's role.";
          };
          modes = lib.mkOption {
            type = lib.types.listOf (lib.types.enum ["interactive" "headless" "acp"]);
            default = [];
            description = "Session modes exposing this technique.";
          };
          notes = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Runtime-specific controls and constraints.";
          };
          pinsEffort = lib.mkOption {
            type = lib.types.nullOr lib.types.bool;
            default = null;
            description = "Whether a delegate technique pins effort; null for inspection and usage.";
          };
          pinsModel = lib.mkOption {
            type = lib.types.nullOr lib.types.bool;
            default = null;
            description = "Whether a delegate technique pins the model; null for inspection and usage.";
          };
        };
      });
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
                type = lib.types.enum tiers;
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
            defaultContent.text = defaults.procedure.text;
            description = "delegate routing procedure";
            enableDefault = true;
          };
          default = {};
          description = "Procedure at the end of the skill. Replace with text or source, or disable it.";
        };
        rules = lib.mkOption {
          type = aiTypes.optionalTextSource {
            defaultContent.text = defaults.rules.text;
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
          rules = {inherit (portable.rules) enable text;};
          procedure = {inherit (portable.procedure) enable text;};
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
            families = lib.mapAttrs (_: lib.mapAttrs (_: lib.mapAttrs (_: lib.mkDefault))) defaults.families;
            whenToDelegate = {
              "Launch independent work together" = mkPreset {source = ../fragments/launch-independent-work-together.md;};
              "Orchestrator session" = mkPreset {source = ../fragments/orchestrator-session.md;};
              "Prefer the flat-rate pool" = mkPreset {source = ../fragments/prefer-the-flat-rate-pool.md;};
              "Verify by the artifact" = mkPreset {source = ../fragments/verify-by-the-artifact.md;};
            };
          };
        }
        (lib.genAttrs supportedRuntimes (runtime: {
          programs.delegate-routing.techniques = lib.mapAttrs (_: lib.mapAttrs (_: lib.mkDefault)) defaults.techniques.${runtime};
        }))
      ];
      assertions =
        (
          if options ? warnings
          then lib.id
          else emitWarnings
        )
        (
          # Reject automatic external delegates whose runtime is disabled.
          lib.concatMap (runtime:
            map (target: {
              assertion = !(programEnabled runtime && runtimeEnabled runtime) || runtimeEnabled target;
              message = "ai.${runtime}.programs.delegate-routing.extraRuntimes includes `${target}`, but ai.${target}.enable is false. Enable that runtime or use manualExternalDelegates.";
            })
            (lib.subtractLists
              config.ai.${runtime}.programs.delegate-routing.manualExternalDelegates
              config.ai.${runtime}.programs.delegate-routing.extraRuntimes))
          present
          ++ lib.concatMap (runtime: let
            path = "ai.${runtime}.programs.delegate-routing";
          in [
            {
              assertion = !(programEnabled runtime && runtimeEnabled runtime) || select portable.families models.${runtime} != [];
              message = "${path}.models must select at least one configured family when the program and runtime are enabled.";
            }
          ])
          present
          ++ lib.concatMap (
            runtime: let
              path = "ai.${runtime}.programs.delegate-routing";
              vendors = builtins.attrNames portable.families;
              names = lib.unique (lib.concatMap (vendor: builtins.attrNames portable.families.${vendor}) vendors);
              configuredTiers = lib.unique (lib.concatMap (vendor: map (family: family.tier) (builtins.attrValues portable.families.${vendor})) vendors);
            in
              lib.concatMap (selector: [
                {
                  assertion = selector.vendors != [] || selector.tiers != [] || selector.families != [];
                  message = "${path}.models contains an empty selector; specify vendors, tiers or families.";
                }
                {
                  assertion =
                    lib.all (vendor: builtins.elem vendor vendors) selector.vendors
                    && lib.all (tier: builtins.elem tier configuredTiers) selector.tiers
                    && lib.all (family: builtins.elem family names) selector.families;
                  message = "${path}.models references a vendor, tier or family absent from ai.programs.delegate-routing.families.";
                }
              ])
              models.${runtime}
              ++ lib.concatLists (lib.mapAttrsToList (name: node: let
                  delegate = builtins.elem node.kind ["workflow" "subagent" "external"];
                in [
                  {
                    assertion = (node.pinsModel != null) == delegate && (node.pinsEffort != null) == delegate;
                    message = "${path}.techniques.${name}: pinsModel and pinsEffort must be non-null exactly for workflow, subagent and external techniques.";
                  }
                  {
                    assertion = node.kind != "external" || node.command != null;
                    message = "${path}.techniques.${name}.command is required for an external technique.";
                  }
                ])
                techniques.${runtime})
          )
          supportedRuntimes
        );
    }
    // lib.optionalAttrs (options ? warnings) {
      warnings = warningMessages;
    };
}
