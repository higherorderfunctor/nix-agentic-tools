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
    textType ? lib.types.lines,
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

        _sourceWins = lib.mkOption {
          type = lib.types.bool;
          default = sourceWins config options;
          description = "Whether source supplies the effective text-source content.";
          internal = true;
          readOnly = true;
          visible = false;
        };

        source = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "A file whose contents become ${description}. The higher-priority definition of `source` or `text` supplies the content; defining both at the same priority is an error.";
        };

        text = lib.mkOption {
          type = textType;
          default = "";
          description = "The inline ${description}. The higher-priority definition of `text` or `source` supplies the content; defining both at the same priority is an error. Enabled or required records need non-empty inline text unless a source supplies the content.";
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
    enableOnMkDefault,
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
    # `defaultContent` is installed at `mkDefault`, so by default only content
    # above that priority is a consumer's and enables the record: package
    # prose stays dormant until someone opts in. A record with no
    # `defaultContent` has no dormant prose to protect, and may opt into
    # treating a `mkDefault` definition as content too.
    enablesRecord = field:
      if enableOnMkDefault
      then options.${field}.highestPrio <= defaultPriority
      else options.${field}.highestPrio < defaultPriority;
    contentIsExplicit = enablesRecord "text" || enablesRecord "source";
    contentIsPresent =
      if contentUsesSource
      then true
      else mergedText.mergedValue != "";
  in {
    options = {
      # Whether any definition of `enable` exists, at whatever priority —
      # including a generator's whole-entry `mkDefault`. It separates a record
      # someone switched off from one that merely has nothing in it.
      _enableDefined = lib.mkOption {
        type = lib.types.bool;
        default = options.enable.highestPrio <= defaultPriority;
        internal = true;
        readOnly = true;
        visible = false;
      };
      enable = lib.mkOption {
        type = lib.types.bool;
        default = enableDefault;
        description = "Whether to include ${description}. Content supplied through non-empty `text` or a `source` at ${
          if enableOnMkDefault
          then "any priority, `mkDefault` included,"
          else "consumer priority"
        } enables it automatically; setting `enable = false` omits it while retaining that content. An enabled or required text source without content is an evaluation error.";
      };
    };

    config.enable = lib.mkIf (contentIsExplicit && contentIsPresent) (lib.mkDefault true);
  };
  textSourceUsesSource = value:
    value._sourceWins or (!(value ? text) && (value.source or null) != null);
in {
  inherit extendSubmodule;

  inherit textSourceUsesSource;

  # The inline text an enabled record delivers, or null when it is disabled or
  # a `source` supplies it. Reading `text` of a source-backed record would
  # `readFile` the source at evaluation time, which for a derivation output is
  # import-from-derivation; callers that measure bytes stay lazy through this.
  textSourceInlineText = value:
    if !value.enable || textSourceUsesSource value
    then null
    else value.text;

  # An optional text source lowered to its text when enabled, or to null so a
  # renderer's null-pruning drops the key. The type rejects enabled empty
  # text, so this only decides whether the value is enabled.
  enabledTextOrNull = value:
    if value.enable
    then value.text
    else null;

  textSourceFile = value:
    if textSourceUsesSource value
    then {inherit (value) source;}
    else {inherit (value) text;};

  optionalTextSource = {
    defaultContent ? {},
    description,
    enableDefault ? false,
    enableOnMkDefault ? false,
    textType ? lib.types.lines,
  }: let
    baseType = mkTextSource {inherit defaultContent description textType;};
  in
    if enableOnMkDefault && defaultContent != {}
    then throw "optionalTextSource: `enableOnMkDefault` would enable its own `defaultContent` (${description}); a record carries at most one of them."
    else extendSubmodule baseType (mkEnableModule {inherit description enableDefault enableOnMkDefault;});

  textSource = mkTextSource;
}
