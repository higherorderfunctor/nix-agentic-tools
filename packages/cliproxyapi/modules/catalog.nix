# CPA owns served spellings separately from the shared static identities.
{lib, ...}: let
  # Owners load their extraction once and supply independent module defaults.
  vendors = import ../lib/vendors {inherit lib;};
in {
  options.ai.cliproxyapi.servedModels = lib.mkOption {
    type = lib.types.attrsOf (lib.types.attrsOf (lib.types.listOf lib.types.nonEmptyStr));
    default = {};
    description = "Vendor-owned canonical model ids mapped to exact served spellings; consumers can extend each mapping or clear it with an empty list.";
  };
  config = {
    ai.catalog = lib.mkMerge (map (lib.mapAttrsRecursive (_: lib.mkDefault)) vendors.catalogs);
    ai.cliproxyapi.servedModels = lib.mapAttrsRecursive (_: lib.mkDefault) vendors.servedModels;
  };
}
