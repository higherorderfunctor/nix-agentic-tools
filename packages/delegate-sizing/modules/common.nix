{
  config,
  lib,
  options,
  ...
}: let
  # Resolve the supported runtimes and their instruction presets. Kimchi has
  # no delegate primitive; Copilot's sizing controls are not established.
  supportedRuntimes = ["claude" "codex" "kiro"];
  presets = import ../lib/presets.nix;
  enabled = runtime:
    config.ai.${runtime}.programs.delegate-sizing.enable
    or null;
  programEnabled = runtime:
    if enabled runtime == null
    then config.ai.programs.delegate-sizing.enable
    else enabled runtime;
  runtimeEnabled = runtime: lib.attrByPath ["ai" runtime "enable"] false config;
  present = builtins.filter (runtime: lib.hasAttrByPath ["ai" runtime "skills"] options) supportedRuntimes;
  settings = lib.genAttrs supportedRuntimes (runtime: config.ai.${runtime}.programs.delegate-sizing.settings);

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
        type = lib.types.either (lib.types.enum [false]) lib.types.str;
        default = preset;
        description = "${runtime} ${name} instruction block. A string replaces the package preset; false omits the block. launch is used when this runtime is an external delegate in another runtime's skill.";
      })
    presets.${runtime};
  };
in {
  options.ai = lib.genAttrs supportedRuntimes (runtime: {
    programs.delegate-sizing = lib.mkOption {
      type = lib.types.submodule {options = runtimeOptions runtime;};
    };
  });

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
      rules = _: import ../router.nix;
    })
  ];

  # Reject automatic external delegates whose runtime is disabled.
  config.assertions = lib.concatMap (runtime:
    map (target: {
      assertion = !(programEnabled runtime && runtimeEnabled runtime) || runtimeEnabled target;
      message = "ai.${runtime}.programs.delegate-sizing.extraRuntimes includes `${target}`, but ai.${target}.enable is false. Enable that runtime or use manualExternalDelegates.";
    })
    (lib.subtractLists
      config.ai.${runtime}.programs.delegate-sizing.manualExternalDelegates
      config.ai.${runtime}.programs.delegate-sizing.extraRuntimes))
  present;
}
