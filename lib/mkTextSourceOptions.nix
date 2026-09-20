# cspell:ignore highestPrio
{lib}: {
  submodule = prose: {
    config,
    options,
    ...
  }: let
    defaultPriority = (lib.mkDefault null).priority;
    sameExplicitPriority =
      options.text.highestPrio
      == options.source.highestPrio
      && (
        options.text.highestPrio
        != defaultPriority
        || builtins.length options.text.definitionsWithLocations > 1
      );
  in {
    options = {
      _textSourceConflict = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        internal = true;
        visible = false;
      };

      source = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "A file whose contents become ${prose}.";
      };

      text = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "The ${prose}.";
      };
    };

    config = {
      _textSourceConflict = lib.mkIf (config.source != null && sameExplicitPriority) ''
        `${lib.showOption options.text.loc}` and `${lib.showOption options.source.loc}` are defined at the same priority. Set only one of these options.
      '';
      text = lib.mkIf (config.source != null) (lib.mkDefault (builtins.readFile config.source));
    };
  };

  assertions = prefix: entries:
    lib.concatLists (lib.mapAttrsToList (name: entry:
      lib.optional (entry._textSourceConflict != null) {
        assertion = false;
        message = "${lib.showOption (prefix ++ [name])}: ${entry._textSourceConflict}";
      })
    entries);
}
