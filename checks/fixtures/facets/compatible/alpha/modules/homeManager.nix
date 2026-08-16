args @ {
  fixtureToken,
  hmOnly,
  lib,
  ...
}: {
  options.facetMock.homeManager = {
    observed = lib.mkOption {type = lib.types.str;};
    sawDevenvOnly = lib.mkOption {type = lib.types.bool;};
  };

  config.facetMock.homeManager = {
    observed = "${fixtureToken}:${hmOnly}";
    sawDevenvOnly = args ? devenvOnly;
  };
}
