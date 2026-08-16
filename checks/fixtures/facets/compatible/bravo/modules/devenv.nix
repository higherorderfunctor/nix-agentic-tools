args @ {
  devenvOnly,
  fixtureToken,
  lib,
  ...
}: {
  options.facetMock.devenv = {
    observed = lib.mkOption {type = lib.types.str;};
    sawHmOnly = lib.mkOption {type = lib.types.bool;};
  };

  config.facetMock.devenv = {
    observed = "${fixtureToken}:${devenvOnly}";
    sawHmOnly = args ? hmOnly;
  };
}
