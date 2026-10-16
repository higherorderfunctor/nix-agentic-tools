{
  lib,
  pkgs ? null,
  ...
}: let
  activation = import ../lib/activation.nix {inherit lib;};
  files2 = import ../lib/files/default.nix {inherit lib pkgs;};
in {
  options.ai = {
    activation2 = lib.mkOption {
      type = lib.types.attrsOf activation.entryType;
      default = {};
    };
    activation2Order.secretNodes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
    };
    files2 = lib.mkOption {
      type = lib.types.attrsOf files2.entryType;
      default = {};
    };
    # Destination -> declaring runtimes; written by `runtimeModule` only.
    files2Owners = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = {};
      internal = true;
    };
    # Old ledgers to import; written by `runtimeModule` only.
    legacyLedgers = lib.mkOption {
      type = lib.types.listOf files2.legacyLedgerType;
      default = [];
      internal = true;
    };
  };
}
