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
    description = "Plan substantive work, validate launches and size delegates with the runtime routing helper.";
    name = "delegate-routing";
  };
  mkUsageScript = name: runtimeInputs: parts:
    (import ../../../../lib/strict-shell-application.nix pkgs) {
      inherit name runtimeInputs;
      text = lib.concatMapStringsSep "\n" builtins.readFile ([../../scripts/usage-cpa.sh] ++ parts);
    };
  usageScripts = {
    claude-usage = mkUsageScript "claude-usage" [pkgs.curl pkgs.jq] [../../scripts/claude-usage.sh];
    codex-usage = mkUsageScript "codex-usage" [pkgs.coreutils pkgs.curl pkgs.jq pkgs.python3] [../../scripts/codex-usage.sh];
    opencode-usage = mkUsageScript "opencode-usage" [pkgs.curl pkgs.jq pkgs.python3] [../../scripts/opencode-usage.sh];
    proxy-accounted-usage = mkUsageScript "proxy-accounted-usage" [pkgs.curl pkgs.jq pkgs.python3] [../../scripts/proxy-accounted-usage.sh];
    zai-usage = mkUsageScript "zai-usage" [pkgs.curl pkgs.jq pkgs.python3] [../../scripts/zai-usage.sh];
  };
  rawDefaults = import ../../lib/defaults.nix {
    inherit lib;
    claudeUsageScript = lib.getExe usageScripts.claude-usage;
    codexUsageScript = lib.getExe usageScripts.codex-usage;
  };
  techniqueType = import ../../lib/technique-type.nix {inherit lib;};
  entryTypes = import ../../lib/entry-type.nix {inherit lib;};
  # Caller techniques for mkSkill get the same option defaults as the shipped set.
  normalizeTechniques = techniques:
    (lib.evalModules {
      modules = [
        {
          options.techniques = lib.mkOption {
            type = lib.types.attrsOf (lib.types.attrsOf techniqueType);
          };
          config = {inherit techniques;};
        }
      ];
    }).config.techniques;
  normalized =
    (lib.evalModules {
      modules = [
        {
          options =
            entryTypes.options
            // {
              techniques = lib.mkOption {
                type = lib.types.attrsOf (lib.types.attrsOf techniqueType);
              };
            };
          config = lib.mapAttrsRecursive (_: lib.mkDefault) {inherit (rawDefaults) routing skill workflows techniques;};
        }
      ];
    }).config;
  defaults = rawDefaults // {inherit (normalized) routing skill workflows techniques;};
  render = args: builtins.readFile "${mkSkill args}/SKILL.md";
  # The skill in the house prose style. No table check: this package set's
  # pkgs carries no overlay, so the overlay's linters are not in it.
  # Defaults merge before the overridable builder, so a direct caller's
  # `.override (prev: ...)` reads the shipped inputs, `prev.skill` included.
  mkSkill = args: lib.makeOverridable buildSkill (defaults // {sessionPool = null;} // args);
  buildSkill = args: let
    techniques = normalizeTechniques args.techniques;
    view = import ../../lib/routing-view.nix {
      inherit lib pools techniques;
      inherit (args) classifiers runtime families models;
      resolvedAgentFiles = args.resolvedAgentFiles or null;
      extraRuntimes = args.extraRuntimes or [];
      manualExternalDelegates = args.manualExternalDelegates or [];
    };
    pools = args.pools or {};
    manifest = pkgs.writeText "delegate-routing-${args.runtime}-manifest.json" (builtins.toJSON (
      if args.sessionPool != null && !(builtins.hasAttr args.sessionPool pools)
      then throw "delegate-routing.runtimes.${args.runtime}.sessionPool: unknown pool `${args.sessionPool}`"
      else view // {inherit (args) runtime sessionPool;}
    ));
    helper = (import ../../../../lib/strict-shell-application.nix pkgs) {
      name = "delegate-routing-plan";
      text = ''
        exec ${pkgs.python3}/bin/python3 ${../../scripts/delegate-routing-plan.py} "$@" --manifest ${manifest} --reader-shell ${pkgs.bash}/bin/bash
      '';
    };
    helperCommand = lib.getExe helper;
    helperInstruction = "Runtime: ${args.runtime}; session pool: ${
      if args.sessionPool == null
      then "unknown (buffer cannot be certified)"
      else args.sessionPool
    }. Run `${helperCommand} --role <role> --launch-context <json-path>` before choosing a route. The command collects registered Readers and prints JSON and canonical routing specifications; it never launches delegates. Use the launch-context guidance below.";
    # Build the compulsory heavy context first. Its absolute path can then be
    # embedded in SKILL.md without referring to that skill's own output.
    renderContext = audience: plannerReference:
      builtins.appendContext
      (import ../../lib/render.nix ({inherit lib;} // lib.removeAttrs args ["sessionPool"] // {inherit audience helperInstruction plannerReference techniques;}))
      (builtins.getContext helperInstruction);
    planner = generated.mkTree {
      name = "delegate-routing-${args.runtime}-planner";
      files."PLANNER.md" = {
        type = "markdown";
        text = renderContext "planner" "";
      };
      guards.parseCompare = true;
      inherit (args) runtime;
      inherit treefmt;
    };
    plannerReference = "${planner}/PLANNER.md";
  in
    generated.mkTree {
      name = "delegate-routing-${args.runtime}-skill";
      files = {
        "PLANNER.md" = {
          type = "raw";
          source = plannerReference;
        };
        "SKILL.md" = {
          type = "markdown";
          text = frontmatter.render {
            data = skillData;
            body = renderContext "orchestrator" plannerReference;
          };
        };
      };
      guards.parseCompare = true;
      passthru = {
        text = render args;
      };
      inherit (args) runtime;
      inherit treefmt;
    };
  skills = lib.genAttrs (builtins.attrNames (lib.filterAttrs (_: models: models != []) defaults.models)) (runtime: mkSkill {inherit runtime;});
in
  pkgs.runCommand "delegate-routing-content" {
    passthru = {
      fragments = import ../../lib/fragments.nix {inherit fragmentsLib repoPath;};
      inherit mkSkill render skills usageScripts;
      inherit (defaults) classifiers families models techniques routing skill workflows;
    };
  } ''
    # Full strict mode is required here: stdenv does not set every flag (#909).
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    mkdir -p "$out/fragments" "$out/skills"
    cp ${../../fragments/load-delegate-routing.md} "$out/fragments/load-delegate-routing.md"
    ${lib.concatMapStringsSep "\n" (runtime: "cp -r ${skills.${runtime}} \"$out/skills/${runtime}\"") (builtins.attrNames skills)}
  ''
