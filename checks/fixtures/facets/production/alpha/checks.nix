{
  inputs,
  overlayResult,
  pkgs,
  registry,
  ...
}: {
  alpha-overlay-order = assert registry.facetMock.entries.alpha.payload == "alpha";
  assert overlayResult.ai.alpha == "${inputs.fixture.sentinel}:alpha";
    pkgs.runCommandLocal "facet-alpha-overlay-order" {} ''
      mkdir -p "$out"
      touch "$out/passed"
    '';
}
