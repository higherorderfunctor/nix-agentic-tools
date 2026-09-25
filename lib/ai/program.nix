# Factory for portable program option trees.
{lib}: let
  aiCommon = import ./ai-common.nix {inherit lib;};

  # `transform` receives each option's path below the program root.
  mapOptionTree = transform: path:
    lib.mapAttrs (name: value:
      if lib.isOption value
      then transform (path ++ [name]) value
      else mapOptionTree transform (path ++ [name]) value);

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

  # A keyed pool (an `attrsOf` option listed in the spec's `pools`) is
  # overridden per key rather than wholesale. Its runtime option holds
  # nullable entries: a runtime entry replaces the portable entry at the same
  # key, and a runtime null drops it. This is the keyed-pool rule, applied to
  # a program option. The portable option's `apply` stays portable-only: it
  # has already shaped the portable pool the runtime entries merge into, and
  # it was written for non-null entries.
  mkPoolOverrideOption = path: option:
    assert lib.assertMsg ((option.type.name or null) == "attrsOf")
    "mkProgram: pool `${lib.concatStringsSep "." path}` must be an attrsOf option.";
      (builtins.removeAttrs option ["apply" "default" "defaultText" "example"])
      // {
        default = {};
        type = lib.types.attrsOf (lib.types.nullOr option.type.nestedTypes.elemType);
        description = ''
          ${option.description or ""}

          Runtime override for the portable pool, resolved per key: an entry
          replaces the portable entry with the same name, and null removes it.
        '';
      };

  resolveTree = pools: path: declarations: portable: override:
    lib.mapAttrs (name: declaration: let
      optionPath = path ++ [name];
    in
      if lib.isOption declaration
      then
        if lib.elem optionPath pools
        then
          aiCommon.mergePool {
            topPool = portable.${name};
            cliPool = override.${name};
          }
        else
          aiCommon.resolveOverride {
            topValue = portable.${name};
            cliValue = override.${name};
          }
      else resolveTree pools optionPath declaration portable.${name} override.${name})
    declarations;
in {
  mkProgram = spec @ {
    name,
    options,
    # Option paths, relative to the program root, of `attrsOf` options whose
    # runtime overrides resolve per key (see `mkPoolOverrideOption`).
    pools ? [],
    supportedRuntimes,
  }: let
    # A pool path that names no option would silently keep the wholesale
    # override the pool exists to prevent.
    unknownPools = builtins.filter (path: !(lib.hasAttrByPath path options && lib.isOption (lib.getAttrFromPath path options))) pools;
    overrideOptions = mapOptionTree (path: option:
      if lib.elem path pools
      then mkPoolOverrideOption path option
      else mkOverrideOption option) []
    options;
    mkProgramOption = optionDeclarations: description:
      lib.mkOption {
        type = lib.types.submodule {options = optionDeclarations;};
        default = {};
        inherit description;
      };
  in
    assert lib.assertMsg (unknownPools == [])
    "mkProgram `${name}`: pools ${lib.concatMapStringsSep ", " (path: "`${lib.concatStringsSep "." path}`") unknownPools} name no option."; {
      inherit name options pools spec supportedRuntimes;

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
          pools
          []
          options
          config.ai.programs.${name}
          config.ai.${runtime}.programs.${name};
    };
}
