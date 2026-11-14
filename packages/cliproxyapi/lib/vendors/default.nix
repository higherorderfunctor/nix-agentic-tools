# Vendor index joins static contributions and constructs defaults for module and standalone callers.
{
  lib,
  catalog ? null,
  servedModels ? null,
}: let
  # Each vendor owns extraction, identity evidence and transport construction.
  definitions = {
    opencode-go = import ./opencode-go.nix {inherit lib;};
    zhipuai = import ./zhipuai.nix {inherit lib;};
  };
in {
  # Contributions never depend on the merged catalog passed to constructors.
  catalogs = map (vendor: vendor.catalog) (builtins.attrValues definitions);
  # CPA modules expose these owner defaults through their extensible option.
  servedModels = lib.mapAttrs (_: vendor: vendor.servedModels) definitions;
  # Preserve the synthetic native-API placement callable used by existing checks.
  inherit (definitions.opencode-go) opencodeGo;
  # Standalone callers use the same constructor with each vendor's own static facts.
  vendors = lib.mapAttrs (name: vendor: let
    # Standalone callers have only the owner's catalog; module callers use merged identities.
    merged =
      if catalog == null
      then vendor.catalog
      else catalog;
    # Equal-priority owners may attest the same offer; each model is constructed once.
    ids = lib.unique merged.vendors.${name}.models;
    # Refuse missing identities before either transport constructor reads or renders them.
    checked = map (id:
      if merged.models ? ${id}
      then id
      else throw "ai.catalog.vendors.${name}.models names unknown model `${id}`; declare ai.catalog.models.${id} or remove the id from the vendor list.")
    ids;
  in
    builtins.deepSeq checked (vendor.construct (
        if servedModels == null
        then vendor.servedModels
        else servedModels.${name} or {}
      ) (merged
        // {
          vendors = merged.vendors // {${name} = merged.vendors.${name} // {models = checked;};};
        })))
  definitions;
}
