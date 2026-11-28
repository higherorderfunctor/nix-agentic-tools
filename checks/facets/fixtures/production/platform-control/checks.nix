{
  lib,
  packages,
  pkgs,
  system,
  ...
}: let
  admitted = system == "aarch64-darwin";
in {
  checks.platform-omission =
    # Reject a missing or substituted recipe on the admitted system.
    assert lib.assertMsg (!admitted || packages.ai.devTools.unsupported-control.name == "facet-platform-control")
    "platform-control: unsupported-control must resolve to facet-platform-control on ${system}";
      pkgs.runCommandLocal "facet-platform-omission" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        mkdir -p "$out"
        touch "$out/passed"
      '';
}
