{lib, ...}: let
  spec = import ../../module-spec.nix;
in {
  options.facetMock.shared = {
    backend = lib.mkOption {type = lib.types.str;};
    enabled = lib.mkOption {type = lib.types.bool;};
    label = lib.mkOption {type = lib.types.str;};
  };

  config.facetMock.shared = {
    backend = "devenv";
    inherit (spec) enabled label;
  };
}
