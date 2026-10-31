{
  lib,
  pkgs,
  ...
}: let
  package = pkgs.ai.airlock;
in {
  imports = [./checks/airlock-instances.nix];

  checks.airlock-package = pkgs.runCommandLocal "airlock-package" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :

    ${lib.getExe package} --help | grep -F -- 'local egress proxy'
    ${lib.getExe package} --version | grep -F -- 'airlock ${package.version}'
    mkdir -p "$out"
  '';
}
