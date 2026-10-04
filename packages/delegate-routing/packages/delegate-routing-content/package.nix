{
  fragmentsLib,
  generatedLib,
  inputs,
  pkgs,
  repoPath,
  ...
}: let
  inherit (pkgs) lib;
  generated = generatedLib pkgs;
  frontmatter = import ../../../../lib/frontmatter.nix {inherit lib;};
  treefmt = (inputs.treefmt-nix.lib.evalModule pkgs ../../../../lib/treefmt-module.nix).config;
  skillData = {
    description = "Before calling a subagent, spawning a delegate, or building a workflow, size the model and effort for the task and available runtime pools.";
    name = "delegate-routing";
  };
  mkUsageScript = name: runtimeInputs:
    pkgs.writeShellApplication {
      inherit name runtimeInputs;
      bashOptions = ["errexit" "errtrace" "functrace" "nounset" "pipefail"];
      text = builtins.readFile (../../scripts + "/${name}.sh");
    };
  usageScripts = {
    claude-usage = mkUsageScript "claude-usage" [pkgs.curl pkgs.jq];
    codex-usage = mkUsageScript "codex-usage" [pkgs.coreutils pkgs.jq pkgs.python3];
  };
  rawDefaults = import ../../lib/defaults.nix {
    claudeUsageScript = lib.getExe usageScripts.claude-usage;
    codexUsageScript = lib.getExe usageScripts.codex-usage;
  };
  techniqueType = import ../../lib/technique-type.nix {inherit lib;};
  normalizedTechniques =
    (lib.evalModules {
      modules = [
        {
          options.techniques = lib.mkOption {
            type = lib.types.attrsOf (lib.types.attrsOf techniqueType);
            default = rawDefaults.techniques;
          };
        }
      ];
    }).config.techniques;
  defaults = rawDefaults // {techniques = normalizedTechniques;};
  render = args: builtins.readFile "${mkSkill args}/SKILL.md";
  # The skill in the house prose style. No table check: this package set's
  # pkgs carries no overlay, so the overlay's linters are not in it.
  mkSkill = args:
    generated.mkTree {
      name = "delegate-routing-${args.runtime}-skill";
      files."SKILL.md" = {
        type = "markdown";
        text = frontmatter.render {
          data = skillData;
          body = import ../../lib/render.nix ({inherit lib;} // defaults // args);
        };
      };
      guards.parseCompare = true;
      passthru.text = render args;
      inherit (args) runtime;
      inherit treefmt;
    };
  skills = lib.genAttrs (builtins.attrNames (lib.filterAttrs (_: models: models != []) defaults.models)) (runtime: mkSkill {inherit runtime;});
in
  pkgs.runCommand "delegate-routing-content" {
    passthru = {
      fragments = import ../../lib/fragments.nix {inherit fragmentsLib repoPath;};
      inherit mkSkill render skills usageScripts;
      inherit (defaults) families models techniques rules procedure roles;
    };
  } ''
    # Full strict mode is required here: stdenv does not set every flag (#909).
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    mkdir -p "$out/fragments" "$out/skills"
    cp ${../../fragments/skill-routing.md} "$out/fragments/skill-routing.md"
    ${lib.concatMapStringsSep "\n" (runtime: "cp -r ${skills.${runtime}} \"$out/skills/${runtime}\"") (builtins.attrNames skills)}
  ''
