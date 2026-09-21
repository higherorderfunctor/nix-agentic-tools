# cspell:ignore highestPrio
{lib}: let
  defaultPriority = (lib.mkDefault null).priority;
  mkTextSource = {
    description,
    enableDefault ? null,
  }:
    lib.types.submodule ({
      config,
      options,
      ...
    }: let
      sameExplicitPriority =
        options.text.highestPrio
        == options.source.highestPrio;
      contentIsExplicit =
        options.text.highestPrio
        < defaultPriority
        || options.source.highestPrio < defaultPriority;
    in {
      options =
        {
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
              else if sameExplicitPriority
              then throw "`${lib.showOption options.text.loc}` and `${lib.showOption options.source.loc}` are defined at the same priority. Set only one of these options."
              else if options.text.highestPrio < defaultPriority
              then value
              else builtins.readFile config.source;
          };
        }
        // lib.optionalAttrs (enableDefault != null) {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = enableDefault;
            description = "Whether to include ${description}.";
          };
        };

      config = lib.optionalAttrs (enableDefault != null) {
        enable = lib.mkIf contentIsExplicit (lib.mkDefault true);
      };
    });
in {
  optionalTextSource = {
    description,
    enableDefault ? false,
  }:
    mkTextSource {inherit description enableDefault;};

  textSource = {description}: mkTextSource {inherit description;};
}
