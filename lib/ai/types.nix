# cspell:ignore highestPrio
{lib}: let
  defaultPriority = (lib.mkDefault null).priority;
  sourceWins = config: options:
    config.source
    != null
    && options.source.highestPrio < options.text.highestPrio;
  extendSubmodule = baseType: module:
    lib.types.submoduleWith {
      modules = baseType.getSubModules ++ [module];
      # Match `lib.types.submodule`: these types are configuration records, so
      # shorthand definitions must populate `config` rather than module syntax.
      shorthandOnlyDefinesConfig = true;
    };
  mkTextSource = {description}:
    lib.types.submodule ({
      config,
      options,
      ...
    }: let
      samePriority =
        options.text.highestPrio
        == options.source.highestPrio;
    in {
      options = {
        source = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "A file whose contents become ${description}.";
        };

        text = lib.mkOption {
          type = lib.types.lines;
          default = "";
          description = "The ${description}.";
          apply = value:
            if config.source == null
            then value
            else if samePriority
            then throw "`${lib.showOption options.text.loc}` and `${lib.showOption options.source.loc}` are defined at the same priority. Set only one of these options."
            else if sourceWins config options
            then builtins.readFile config.source
            else value;
        };
      };
    });
  mkEnableModule = {
    description,
    enableDefault,
  }: {
    config,
    options,
    ...
  }: let
    contentUsesSource = sourceWins config options;
    contentIsExplicit =
      options.text.highestPrio
      < defaultPriority
      || options.source.highestPrio < defaultPriority;
    contentIsPresent =
      if contentUsesSource
      then true
      else config.text != "";
  in {
    options.enable = lib.mkOption {
      type = lib.types.bool;
      default = enableDefault;
      description = "Whether to include ${description}.";
    };

    config.enable = lib.mkIf (contentIsExplicit && contentIsPresent) (lib.mkDefault true);
  };
in {
  inherit extendSubmodule;

  optionalTextSource = {
    description,
    enableDefault ? false,
  }: let
    baseType = mkTextSource {inherit description;};
  in
    extendSubmodule baseType (mkEnableModule {inherit description enableDefault;});

  textSource = mkTextSource;
}
