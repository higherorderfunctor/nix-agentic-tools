{pkgs}: let
  launcher = import ./mkWorkflowRun.nix {inherit pkgs;};
in
  pkgs.runCommand "kimchi-workflow-skill" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    mkdir -p "$out"
    cp ${../skills/kimchi-workflow/SKILL.md} "$out/SKILL.md"
    ln -s ${launcher}/bin "$out/bin"
  ''
