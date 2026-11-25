{
  inputs,
  lib,
  pkgs,
  ...
}: let
  # Read the unmodified Darwin recipe even in the required Linux checks matrix.
  # The check, not ciPackages, throws: a fixed pin can still open an update PR.
  wheel = inputs.nixpkgs.legacyPackages.aarch64-darwin.python3Packages.mitmproxy-macos or {};
  expected =
    (wheel.version or null)
    == "0.12.16"
    && (wheel.src.outputHash or null) == "sha256-7VaT+JsMvR0qjFoxuu0r16dLCq1oZy4IREwYaMOPSfg=";
  message = "nixpkgs no longer has the stale mitmproxy-macos 0.12.16 wheel hash; remove the isDarwin branch in packages/kiro-cli/overlay.nix (keep the claim), the ciPackages kiro-usage-mitmproxy entry in flake.nix, the macOS sentence in packages/kiro-cli/docs/usage-tracking.md, and this check";
in {
  checks.kiro-mitmproxy-macos-pin = assert lib.assertMsg expected message;
    pkgs.runCommand "kiro-mitmproxy-macos-pin" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      touch "$out"
    '';
}
