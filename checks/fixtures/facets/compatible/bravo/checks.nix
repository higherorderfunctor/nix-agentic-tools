{world, ...}: {
  bravo-devenv-isolated =
    world.devenv.config.facetMock.devenv.observed
    == "common:devenv"
    && !world.devenv.config.facetMock.devenv.sawHmOnly;
  bravo-lib-present = world.facetLib.bravo.greeting == "hello-from-bravo";
}
