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
  };
}
