# CPA contributes static vendor facts before consumers construct credential defaults.
{lib, ...}: let
  # The index loads vendor-owned facts without reading config or credentials.
  vendors = import ../lib/vendors {inherit lib;};
in {
  # Default each leaf separately: evidence and aliases merge, conflicting makers fail.
  config.ai.catalog = lib.mkMerge (map (lib.mapAttrsRecursive (_: lib.mkDefault)) vendors.catalogs);
}
