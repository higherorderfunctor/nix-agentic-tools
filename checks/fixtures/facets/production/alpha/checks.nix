{
  inputs,
  overlayResult,
  pkgs,
  ...
}: {
  alpha-overlay-order = assert overlayResult.ai.alpha == "${inputs.fixture.sentinel}:alpha";
    pkgs.runCommandLocal "facet-alpha-overlay-order" {} ''
      mkdir -p "$out"
      touch "$out/passed"
    '';
}
