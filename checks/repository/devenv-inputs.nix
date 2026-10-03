# Local projections of flake inputs must agree without resolving any sources.
{pkgs, ...}: let
  expectedYaml = pkgs.writeText "expected-devenv.yaml" (import ../../config/generate-devenv-yaml.nix {});
in {
  checks.devenv-inputs-drift =
    pkgs.runCommand "devenv-inputs-drift" {
      nativeBuildInputs = [(pkgs.python3.withPackages (ps: [ps.pyyaml]))];
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      python3 ${./devenv-inputs.py} ${../../devenv.yaml} ${expectedYaml} ${../../flake.lock} ${../../devenv.lock}
      touch "$out"
    '';
}
