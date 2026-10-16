{
  config,
  lib,
  pkgs ? null,
  ...
}: let
  activation = import ../lib/activation.nix {inherit lib;};
  fileLib = import ../lib/files/default.nix {inherit lib pkgs;};
in {
  options.ai = {
    activation = lib.mkOption {
      type = lib.types.attrsOf activation.entryType;
      default = {};
    };
    activationOrder.secretNodes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
    };
    deliveredPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Target-relative paths delivered by the enabled file plan, with recursive
        directories represented as `<directory>/**`. Devenv adds them to its
        repository treefmt excludes; other consumers can use the read-only list
        in their own formatter configuration.
      '';
    };
    files = lib.mkOption {
      type = lib.types.attrsOf fileLib.entryType;
      default = {};
    };
    # Destination -> declaring runtimes; written by `runtimeModule` only.
    filesOwners = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = {};
      internal = true;
    };
    # Old ledgers to import; written by `runtimeModule` only.
    legacyLedgers = lib.mkOption {
      type = lib.types.listOf fileLib.legacyLedgerType;
      default = [];
      internal = true;
      # Internal alone still lists the entry's sub-options in option docs.
      visible = false;
    };
  };
  config.ai.deliveredPaths =
    lib.mapAttrsToList
    (path: entry:
      if entry.recursive
      then "${path}/**"
      else path)
    (lib.filterAttrs (_path: entry: entry.enable) config.ai.files);
}
