{
  inputs,
  overlayResult,
  pkgs,
  registry,
  ...
}: {
  _module.args.nativeCheckMarker = "owner-module-argument";
  testing.moduleProbes = [{nativeCheckProbe = true;}];
  checks = {
    alpha-overlay-order = assert inputs.fixture.sentinel == "facet-input-sentinel";
    assert overlayResult.ai.alpha == "facet-input-sentinel:alpha";
    assert registry.facetMock.entries.alpha.payload == "alpha";
      pkgs.writeTextDir "passed" "";
  };
}
