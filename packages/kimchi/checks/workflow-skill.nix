{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) evalDevenv evalHm mkTest;
  skillDir = ".config/kimchi/harness/skills/kimchi-workflow";
  devenvSkillDir = ".kimchi/skills/kimchi-workflow";
  runtimesOn.ai = {
    claude.enable = true;
    kimchi = {
      enable = true;
      native.settings.region = "us";
    };
  };
  enable = lib.recursiveUpdate runtimesOn {ai.programs.kimchi-workflow.enable = true;};
  hmOff = evalHm runtimesOn;
  devenvOff = evalDevenv runtimesOn;
  hmOn = evalHm enable;
  devenvOn = evalDevenv enable;
  keys = result: lib.filter (name: lib.hasPrefix "${devenvSkillDir}/" name) (builtins.attrNames result.config.files);
  override = evaluate: evaluate (lib.recursiveUpdate enable {ai.kimchi.programs.kimchi-workflow.enable = false;});
in {
  checks = {
    module-kimchi-workflow-skill-opt-in = mkTest "kimchi-workflow-skill-opt-in" (
      !(hmOff.config.ai.kimchi.skills ? kimchi-workflow)
      && !(hmOff.config.home.file ? ${skillDir})
      && keys devenvOff == []
    );
    module-kimchi-workflow-skill-delivered = mkTest "kimchi-workflow-skill-delivered" (
      hmOn.config.ai.kimchi.skills ? kimchi-workflow
      && devenvOn.config.ai.kimchi.skills ? kimchi-workflow
      && hmOn.config.home.file.${skillDir}.recursive
      && keys devenvOn == ["${devenvSkillDir}/SKILL.md" "${devenvSkillDir}/bin"]
    );
    module-kimchi-workflow-skill-kimchi-only = mkTest "kimchi-workflow-skill-kimchi-only" (
      !(hmOn.config.ai.claude.skills ? kimchi-workflow)
      && !(devenvOn.config.ai.claude.skills ? kimchi-workflow)
    );
    module-kimchi-workflow-skill-runtime-override = mkTest "kimchi-workflow-skill-runtime-override" (
      !((override evalHm).config.ai.kimchi.skills ? kimchi-workflow)
      && !((override evalHm).config.home.file ? ${skillDir})
      && !((override evalDevenv).config.ai.kimchi.skills ? kimchi-workflow)
      && keys (override evalDevenv) == []
    );
    kimchi-workflow-skill-bin = pkgs.runCommand "kimchi-workflow-skill-bin" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      skill=${hmOn.config.home.file.${skillDir}.source}
      test -s "$skill/SKILL.md"
      for bin in "$skill/bin" ${devenvOn.config.files."${devenvSkillDir}/bin".source}; do
        test -L "$bin"
        test -x "$bin/kimchi-workflow-run"
        test "$(readlink "$bin")" = "${import ../lib/mkWorkflowRun.nix {inherit pkgs;}}/bin"
      done
      echo PASS > "$out"
    '';
  };
}
