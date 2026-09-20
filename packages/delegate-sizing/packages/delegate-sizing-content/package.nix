{
  pkgs,
  fragmentsLib,
  repoPath,
  ...
}: let
  inherit (pkgs) lib;
  # Keep script content independent of the skills that reference its store path.
  scriptContent = pkgs.writeTextFile {
    name = "delegate-sizing-script-content";
    destination = "/scripts/codex-usage.sh";
    text = builtins.readFile ../../scripts/codex-usage.sh;
  };
  presets = import ../../lib/presets.nix {
    codexUsageScript = "${scriptContent}/scripts/codex-usage.sh";
  };
  render = args: builtins.readFile "${mkSkill args}/SKILL.md";
  mkSkill = args: let
    text = import ../../lib/render.nix ({inherit lib presets;} // args);
  in
    pkgs.runCommand "delegate-sizing-${args.runtime}-skill" {
      nativeBuildInputs = [pkgs.prettier];
      passthru.text = render args;
    } ''
      # Full strict mode is required here: stdenv does not set every flag (#909).
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      mkdir -p "$out/scripts"
      install -m 644 ${pkgs.writeText "SKILL.md" text} "$out/SKILL.md"
      cp ${scriptContent}/scripts/codex-usage.sh "$out/scripts/codex-usage.sh"
      prettier --write --prose-wrap always "$out/SKILL.md"
    '';
  skills = lib.genAttrs ["claude" "codex" "kiro"] (runtime: mkSkill {inherit runtime;});
in
  pkgs.runCommand "delegate-sizing-content" {
    passthru = {
      fragments = import ../../lib/fragments.nix {inherit fragmentsLib repoPath;};
      inherit mkSkill presets render skills;
    };
  } ''
    # Full strict mode is required here: stdenv does not set every flag (#909).
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    mkdir -p "$out/fragments" "$out/skills"
    cp ${../../fragments/skill-routing.md} "$out/fragments/skill-routing.md"
    ${lib.concatMapStringsSep "\n" (runtime: "cp -r ${skills.${runtime}} \"$out/skills/${runtime}\"") (builtins.attrNames skills)}
  ''
