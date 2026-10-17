{
  config,
  lib,
  options,
  pkgs ? null,
  ...
}: let
  activation = import ../lib/activation.nix {inherit lib;};
  fileLib = import ../lib/files/default.nix {inherit lib pkgs;};
  services = import ../lib/services.nix {inherit lib;};
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
    claims = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf (lib.types.listOf lib.types.str));
      default = {
        path = {};
        port = {};
        service = {};
      };
      internal = true;
      visible = false;
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
    # Old ledgers to import; written by `runtimeModule` only.
    legacyLedgers = lib.mkOption {
      type = lib.types.listOf fileLib.legacyLedgerType;
      default = [];
      internal = true;
      # Internal alone still lists the entry's sub-options in option docs.
      visible = false;
    };
    services = lib.mkOption {
      type = lib.types.attrsOf services.serviceEntry;
      default = {};
      apply = entries: let
        invalid = lib.findFirst (name: builtins.match "[a-z0-9][a-z0-9_-]*" name == null) null (builtins.attrNames entries);
      in
        if invalid == null
        then entries
        else throw "ai.services.${invalid}: service names must match ^[a-z0-9][a-z0-9_-]*$";
    };
  };
  config =
    {
      ai.deliveredPaths =
        lib.mapAttrsToList
        (path: entry:
          if entry.recursive
          then "${path}/**"
          else path)
        (lib.filterAttrs (_path: entry: entry.enable) config.ai.files);
    }
    // lib.optionalAttrs (options ? assertions) {
      assertions = services.claimAssertions config.ai.claims;
    };
}
