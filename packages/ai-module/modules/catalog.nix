# Static catalog options let owners contribute identities without importing any owner into core.
{lib, ...}: let
  # Core knows only the catalog's field types; owners load their own facts.
  types = import ../lib/catalog/types.nix {inherit lib;};
in {
  # These are the only catalog surfaces: identities and offers, never credentials.
  options.ai.catalog = {
    models = lib.mkOption {
      type = lib.types.attrsOf types.model;
      default = {};
      description = "Static canonical identities contributed by owners and user definitions.";
    };
    providers = lib.mkOption {
      type = lib.types.attrsOf types.provider;
      default = {};
      # Validate at the option boundary after merging: separate definitions must not supply both kinds.
      apply = lib.mapAttrs (name: offer:
        if (offer.models != null) != (offer.maker != null)
        then offer
        else throw "ai.catalog.providers.${name}: declare exactly one of models or maker.");
      description = "Static offers: a finite model list or every model of one maker.";
    };
  };
}
