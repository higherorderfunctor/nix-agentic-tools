{
  inputs,
  lib,
  overlayResult,
  pkgs,
  ...
}: {
  # The namespace peer's imported check must see this contribution in the merged options.
  testing.moduleProbes = [{nativeCheckProbe = true;}];

  # The check can receive stale arguments even when the standalone overlay is correct.
  checks.alpha-overlay-order = assert lib.assertMsg (inputs.fixture.sentinel == "facet-input-sentinel") "the owner check received the wrong fixture input";
  assert lib.assertMsg (overlayResult.ai.alpha == "facet-input-sentinel:alpha") "the owner check did not receive the realized overlay";
    pkgs.writeTextDir "passed" "";
}
