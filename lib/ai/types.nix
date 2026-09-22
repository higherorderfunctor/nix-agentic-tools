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
  mkTextSource = {
    defaultContent ? {},
    description,
  }: let
    baseType = lib.types.submodule ({
      config,
      options,
      ...
    }: let
      samePriority =
        options.text.highestPrio
        == options.source.highestPrio;
    in {
      options = {
        _textSourceType = lib.mkOption {
          type = lib.types.bool;
          default = true;
          internal = true;
          readOnly = true;
          visible = false;
        };

        source = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "A file whose contents become ${description}.";
        };

        text = lib.mkOption {
          type = lib.types.lines;
          default = "";
          description = "The ${description}. Enabled or required records need non-empty inline text unless a source supplies the content.";
          apply = value: let
            sourceIsEffective = sourceWins config options;
            effective =
              if config.source == null
              then value
              else if samePriority
              then throw "`${lib.showOption options.text.loc}` and `${lib.showOption options.source.loc}` are defined at the same priority. Set only one of these options."
              else if sourceIsEffective
              then builtins.readFile config.source
              else value;
          in
            if !sourceIsEffective && (config.enable or true) && effective == ""
            then throw "`${lib.showOption options.text.loc}` must be non-empty when its text source is enabled or required."
            else effective;
        };
      };
    });
  in
    extendSubmodule baseType {
      config = lib.mapAttrs (_: lib.mkDefault) defaultContent;
    };
  mkEnableModule = {
    description,
    enableDefault,
  }: {
    config,
    options,
    ...
  }: let
    contentUsesSource = sourceWins config options;
    # Merge the priority-filtered definitions before `text.apply`: consulting
    # config.text here would cycle through config.enable, and source presence
    # must enable lazily without reading the file.
    mergedText = lib.mergeDefinitions options.text.loc options.text.type options.text.definitionsWithLocations;
    contentIsExplicit =
      options.text.highestPrio
      < defaultPriority
      || options.source.highestPrio < defaultPriority;
    contentIsPresent =
      if contentUsesSource
      then true
      else mergedText.mergedValue != "";
  in {
    options.enable = lib.mkOption {
      type = lib.types.bool;
      default = enableDefault;
      description = "Whether to include ${description}. Enabling requires non-empty `text` or a `source`.";
    };

    config.enable = lib.mkIf (contentIsExplicit && contentIsPresent) (lib.mkDefault true);
  };
in {
  inherit extendSubmodule;

  optionalTextSource = {
    defaultContent ? {},
    description,
    enableDefault ? false,
  }: let
    baseType = mkTextSource {inherit defaultContent description;};
  in
    extendSubmodule baseType (mkEnableModule {inherit description enableDefault;});

  textSource = mkTextSource;
}
