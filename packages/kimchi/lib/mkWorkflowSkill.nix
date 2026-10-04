{pkgs}: let
  launcher = import ./mkWorkflowRun.nix {inherit pkgs;};
in
  pkgs.runCommand "kimchi-workflow-skill" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${pkgs.coreutils}/bin/mkdir -p "$out"
    ${pkgs.coreutils}/bin/cp ${../skills/kimchi-workflow/SKILL.md} "$out/SKILL.md"
    ${pkgs.coreutils}/bin/ln -s ${launcher}/bin "$out/bin"
  ''
