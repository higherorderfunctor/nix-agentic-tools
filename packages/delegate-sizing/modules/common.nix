# cspell:ignore foldr
args @ {
  config,
  lib,
  options,
  pkgs,
  ...
}: let
  delegateSizingRenames = args.delegateSizingRenames or (import ../lib/when-to-delegate-renames.nix);
  # Resolve the supported runtimes and their instruction presets. Kimchi has
  # no delegate primitive; Copilot's sizing controls are not established.
  supportedRuntimes = ["claude" "codex" "kiro"];
  inherit (pkgs.delegate-sizing-content) presets;
  textSourceOptions = import ../../../lib/mkTextSourceOptions.nix {inherit lib;};
  enabled = runtime:
    config.ai.${runtime}.programs.delegate-sizing.enable
    or null;
  # Mirror program.nix's B4 resolveOverride: null inherits the portable value; keep in sync.
  programEnabled = runtime:
    if enabled runtime == null
    then config.ai.programs.delegate-sizing.enable
    else enabled runtime;
  runtimeEnabled = runtime: lib.attrByPath ["ai" runtime "enable"] false config;
  present = builtins.filter (runtime: lib.hasAttrByPath ["ai" runtime "skills"] options) supportedRuntimes;
  settings = lib.genAttrs supportedRuntimes (runtime: config.ai.${runtime}.programs.delegate-sizing.settings);
  whenToDelegateOptions = import ../lib/when-to-delegate.nix {
    inherit lib;
    renames = delegateSizingRenames;
  };
  inherit (whenToDelegateOptions) mkPreset;
  whenToDelegate = config.ai.programs.delegate-sizing.whenToDelegate;
  warningMessages = whenToDelegateOptions.warnings whenToDelegate;
  emitWarnings = value:
    lib.foldr (warning: result: lib.warn warning result) value warningMessages;

  # Declare runtime-only settings alongside the factory's enable override.
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
    settings = lib.mapAttrs (name: preset:
      lib.mkOption {
        type = lib.types.submodule {
          imports = [(textSourceOptions.submodule "the ${runtime} ${name} instruction block")];
          options.enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether to include the ${runtime} ${name} instruction block.";
          };
        };
        default = preset;
        description = "${runtime} ${name} instruction block. Set text or source to replace the package preset. launch is used when this runtime is an external delegate in another runtime's skill.";
      })
    presets.${runtime};
  };
in {
  options.ai =
    lib.genAttrs supportedRuntimes (runtime: {
      # This merges with lib/ai/program.nix's override submodule only because it
      # declares no default, description or example; adding any throws "already declared".
      programs.delegate-sizing = lib.mkOption {
        type = lib.types.submodule {options = runtimeOptions runtime;};
      };
    })
    // {
      programs.delegate-sizing.whenToDelegate = lib.mkOption {
        inherit (whenToDelegateOptions) type;
        default = {};
        apply = whenToDelegateOptions.rename;
        description = "Always-on guidance describing when to delegate work.";
      };
    };

  # Emit one portable enable option and skills/rules for each supported runtime.
  imports = [
    (import ../../../lib/ai/mkSkillPackageModule.nix {
      name = "delegate-sizing";
      enableDescription = "delegate model and effort sizing skills and rule";
      inherit supportedRuntimes;
      skills = {
        pkgs,
        runtime,
        ...
      }: {
        delegate-sizing = "${pkgs.delegate-sizing-content.passthru.mkSkill {
          inherit runtime settings;
          inherit (config.ai.${runtime}.programs.delegate-sizing) extraRuntimes manualExternalDelegates;
        }}";
      };
      rules = _:
        import ../router.nix {
          inherit lib;
          entries = config.ai.programs.delegate-sizing.whenToDelegate;
        };
    })
  ];

  config =
    {
      ai.programs.delegate-sizing.whenToDelegate = {
        "Launch independent work together" = mkPreset {source = ../fragments/launch-independent-work-together.md;};
        "Orchestrator session" = mkPreset {source = ../fragments/orchestrator-session.md;};
        "Prefer the flat-rate pool" = mkPreset {source = ../fragments/prefer-the-flat-rate-pool.md;};
        "Verify by the artifact" = mkPreset {source = ../fragments/verify-by-the-artifact.md;};
      };
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
              message = "ai.${runtime}.programs.delegate-sizing.extraRuntimes includes `${target}`, but ai.${target}.enable is false. Enable that runtime or use manualExternalDelegates.";
            })
            (lib.subtractLists
              config.ai.${runtime}.programs.delegate-sizing.manualExternalDelegates
              config.ai.${runtime}.programs.delegate-sizing.extraRuntimes))
          present
          ++ lib.concatMap (runtime:
            textSourceOptions.assertions
            ["ai" runtime "programs" "delegate-sizing" "settings"]
            settings.${runtime})
          present
          ++ whenToDelegateOptions.assertions
          ["ai" "programs" "delegate-sizing" "whenToDelegate"]
          whenToDelegate
        );
    }
    // lib.optionalAttrs (options ? warnings) {
      warnings = warningMessages;
    };
}
