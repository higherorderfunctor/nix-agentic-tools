{
  lib,
  world,
  ...
}: {
  alpha-home-manager-isolated =
    world.homeManager.config.facetMock.homeManager.observed
    == "common:home-manager"
    && !world.homeManager.config.facetMock.homeManager.sawDevenvOnly;
  alpha-package-realized = lib.isDerivation world.packages.alpha-app;
}
