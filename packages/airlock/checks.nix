{pkgs, ...}: let
  package = pkgs.ai.generic.airlock;
in {
  imports = [./checks/airlock-instances.nix ./checks/claude-launch.nix];

  # nixpkgs' buildRustPackage has no clippy hook, so reuse the package's
  # offline vendored-dependency setup and run clippy instead of the build.
  checks.airlock-clippy = package.overrideAttrs {
    name = "airlock-clippy";
    # A subshell keeps nounset out of the stdenv phases that follow.
    buildPhase = ''
      (
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      runHook preBuild
      cargo clippy --offline --all-targets -- -D warnings
      runHook postBuild
      )
    '';
    doCheck = false;
    installPhase = ''touch "$out"'';
    dontFixup = true;
  };
}
