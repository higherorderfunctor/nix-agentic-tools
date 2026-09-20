{
  pkgs,
  fragmentsLib,
  repoPath,
  ...
}: let
  inherit (pkgs) lib;
  render = args: import ../../lib/render.nix ({inherit lib;} // args);
  mkSkill = args: let
    text = render args;
  in
    pkgs.runCommand "delegate-sizing-${args.runtime}-skill" {
      passthru = {inherit text;};
    } ''
      mkdir -p "$out/scripts"
      cp ${pkgs.writeText "SKILL.md" text} "$out/SKILL.md"
      cp ${pkgs.writeText "codex-usage.sh" (builtins.readFile ../../scripts/codex-usage.sh)} "$out/scripts/codex-usage.sh"
    '';
  skills = lib.genAttrs ["claude" "codex" "kiro"] (runtime: mkSkill {inherit runtime;});
in
  pkgs.runCommand "delegate-sizing-content" {
    passthru = {
      fragments = import ../../lib/fragments.nix {inherit fragmentsLib repoPath;};
      inherit mkSkill render skills;
    };
  } ''
    mkdir -p "$out/fragments" "$out/skills"
    cp ${../../fragments/skill-routing.md} "$out/fragments/skill-routing.md"
    ${lib.concatMapStringsSep "\n" (runtime: "cp -r ${skills.${runtime}} \"$out/skills/${runtime}\"") (builtins.attrNames skills)}
  ''
