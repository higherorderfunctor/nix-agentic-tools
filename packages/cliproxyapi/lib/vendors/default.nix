# Vendor index joins static contributions and constructs defaults for module and standalone callers.
{
  lib,
  catalog ? null,
}: let
  # Each vendor owns extraction, identity evidence and transport construction.
  definitions = {
    opencode-go = import ./opencode-go.nix {inherit lib;};
    z-ai = import ./z-ai.nix {inherit lib;};
  };
in {
  # Contributions never depend on the merged catalog passed to constructors.
  catalogs = map (vendor: vendor.catalog) (builtins.attrValues definitions);
  # Preserve the synthetic native-API placement callable used by existing checks.
  inherit (definitions.opencode-go) opencodeGo;
  # Standalone callers use the same constructor with each vendor's own static facts.
  vendors = lib.mapAttrs (_: vendor:
    vendor.construct (
      if catalog == null
      then vendor.catalog
      else catalog
    ))
  definitions;
}
