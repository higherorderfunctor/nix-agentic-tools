# Factory for portable program option trees.
{lib}: let
  aiCommon = import ./ai-common.nix {inherit lib;};

  mapOptionTree = transform:
    lib.mapAttrs (_: value:
      if lib.isOption value
      then transform value
      else mapOptionTree transform value);

  mkOverrideOption = option: let
    nullableType =
      if option.type.check null
      then option.type
      else lib.types.nullOr option.type;
    description = ''
      Runtime override for the portable program option. null inherits the value
      from `ai.programs`; any non-null value wins.
    '';
  in
    (builtins.removeAttrs option ["default" "defaultText"])
    // {
      default = null;
      type = nullableType;
      description =
        if (option.description or "") == ""
        then description
        else "${option.description}\n\n${description}";
    }
    // lib.optionalAttrs (option ? apply) {
      apply = value:
        if value == null
        then null
        else option.apply value;
    };

  resolveTree = declarations: portable: override:
    lib.mapAttrs (name: declaration:
      if lib.isOption declaration
      then
        aiCommon.resolveOverride {
          topValue = portable.${name};
          cliValue = override.${name};
        }
      else resolveTree declaration portable.${name} override.${name})
    declarations;
in {
  mkProgram = spec @ {
    name,
    options,
    supportedRuntimes,
  }: let
    overrideOptions = mapOptionTree mkOverrideOption options;
    mkProgramOption = optionDeclarations: description:
      lib.mkOption {
        type = lib.types.submodule {options = optionDeclarations;};
        default = {};
        inherit description;
      };
  in {
    inherit name options spec supportedRuntimes;

    module = {
      options.ai =
        {
          programs.${name} = mkProgramOption options "Portable defaults for the ${name} program integration.";
        }
        // lib.genAttrs supportedRuntimes (runtime: {
          programs.${name} = mkProgramOption overrideOptions "${runtime} overrides for the ${name} program integration.";
        });
    };

    resolve = config: runtime:
      assert lib.assertMsg (builtins.elem runtime supportedRuntimes)
      "Program `${name}` does not support runtime `${runtime}`.";
        resolveTree
        options
        config.ai.programs.${name}
        config.ai.${runtime}.programs.${name};
  };
}
