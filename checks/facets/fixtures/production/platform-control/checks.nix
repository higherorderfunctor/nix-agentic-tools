{
  lib,
  omittedPackages,
  packages,
  pkgs,
  system,
  ...
}: let
  admitted = system == "aarch64-darwin";
  expectedOmissions = lib.optional (!admitted) ["ai" "devTools" "unsupported-control"];
in {
  checks.platform-omission =
    # Force the admitted recipe, but require the unsupported leaf to be absent
    # from the projection without evaluating that recipe on other systems.
    assert lib.assertMsg (
      if admitted
      then lib.isDerivation (packages.ai.devTools.unsupported-control or null)
      else !(packages ? ai.devTools.unsupported-control)
    ) "platform-control: unsupported-control must be a derivation on aarch64-darwin and absent elsewhere (tested ${system})";
    assert lib.assertMsg (omittedPackages == expectedOmissions)
    "platform-control: on ${system}, expected omissions ${builtins.toJSON expectedOmissions}, got ${builtins.toJSON omittedPackages}";
      pkgs.runCommandLocal "facet-platform-omission" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        mkdir -p "$out"
        touch "$out/passed"
      '';
}
