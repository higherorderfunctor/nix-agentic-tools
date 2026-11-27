backend: {lib, ...}: {
  options.facetMock.shared = {
    backend = lib.mkOption {type = lib.types.str;};
    enabled = lib.mkOption {type = lib.types.bool;};
    label = lib.mkOption {type = lib.types.str;};
  };

  config.facetMock.shared = {
    inherit backend;
    enabled = true;
    label = "git-revise";
  };
}
