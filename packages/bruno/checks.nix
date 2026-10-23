{pkgs, ...}: let
  package = pkgs.ai.generic.bruno;
in {
  checks.bruno-workspace-lock =
    pkgs.runCommand "bruno-workspace-lock" {
      nativeBuildInputs = [package.nodejs];
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      node ${./checks/normalize-workspace-lock.cjs} \
        ${./src/normalize-workspace-lock.cjs} \
        ${package.nodejs}/lib/node_modules/npm/node_modules/semver
      touch "$out"
    '';
}
