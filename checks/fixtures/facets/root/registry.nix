{lib, ...}: {
  options.facetMock.entries = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        owner = lib.mkOption {type = lib.types.str;};
        payload = lib.mkOption {type = lib.types.str;};
        source = lib.mkOption {type = lib.types.str;};
      };
    });
    default = {};
    description = "Native module values contributed by tracked mock facets.";
  };
}
