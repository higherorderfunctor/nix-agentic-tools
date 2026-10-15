{lib, ...}: let
  activation = import ../lib/activation.nix {inherit lib;};
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
  };
}
