{lib, ...}: let
  inherit (lib) concatStringsSep mkOption types;
  uniqueEntryType = types.mkOptionType {
    name = "unique facet mock registry entry";
    description = "registry entry with exactly one facet owner";
    check = value:
      builtins.isAttrs value
      && value ? owner
      && value ? payload
      && value ? source;
    merge = location: definitions:
      if builtins.length definitions == 1
      then (builtins.head definitions).value
      else let
        left = (builtins.elemAt definitions 0).value;
        right = (builtins.elemAt definitions 1).value;
        keyPath = lib.drop 2 location;
      in
        throw ''
          facet collision in registry at '${concatStringsSep "." keyPath}':
            ${left.owner} (${left.source})
            ${right.owner} (${right.source})
        '';
  };
in {
  options.facetMock.entries = mkOption {
    type = types.attrsOf uniqueEntryType;
    default = {};
    description = "Typed entries contributed by tracked mock facets.";
  };
}
