# Build routing skills and helpers from the same defaults as module consumers.
{
  fragmentsLib,
  generatedLib,
  inputs,
  pkgs,
  repoPath,
  ...
}: let
  inherit (pkgs) lib;
  inherit (import ../../lib/usage-python.nix {inherit pkgs;}) usagePython;
  generated = generatedLib pkgs;
  frontmatter = import ../../../../lib/frontmatter.nix {inherit lib;};
  treefmt = (inputs.treefmt-nix.lib.evalModule pkgs ../../../../lib/treefmt-module.nix).config;
  skillData = {
    description = "Before calling a subagent, spawning a delegate, or building a workflow, size the model and effort for the task and available runtime pools.";
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
    zhipuai-usage = mkUsageScript "zhipuai-usage" [pkgs.curl pkgs.jq pkgs.python3] [../../scripts/zhipuai-usage.sh];
  };
  rawDefaults = import ../../lib/defaults.nix {
    inherit lib;
    claudeUsageScript = lib.getExe usageScripts.claude-usage;
    codexUsageScript = lib.getExe usageScripts.codex-usage;
  };
  techniqueType = import ../../lib/technique-type.nix {inherit lib;};
  entryTypes = import ../../lib/entry-type.nix {inherit lib;};
  opencodeGoPresets = import ../../lib/opencode-go.nix {inherit lib;};
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
  # Manual builders merge the same owner contributions as module callers.
  catalogConfig =
    (lib.evalModules {
      modules = [
        ../../../ai-module/modules/catalog.nix
        ../../../chatgpt-codex/modules/catalog.nix
        ../../../claude-code/modules/catalog.nix
        ../../../cliproxyapi/modules/catalog.nix
      ];
    }).config.ai;
  inherit (catalogConfig) catalog;
  servedModels = catalogConfig.cliproxyapi.servedModels;
  defaults =
    rawDefaults
    // {
      inherit catalog servedModels;
      inherit (normalized) routing skill workflows techniques;
    };
  render = args: builtins.readFile "${mkSkill args}/SKILL.md";
  # The skill in the house prose style. No table check: this package set's
  # pkgs carries no overlay, so the overlay's linters are not in it.
  # Defaults merge before the overridable builder, so a direct caller's
  # `.override (prev: ...)` reads the shipped inputs, `prev.skill` included.
  mkSkill = args:
    lib.makeOverridable buildSkill (defaults
      // {
        picker = null;
        reviewPolicy = (lib.evalModules {modules = [(import ../../lib/review-policy.nix {inherit lib;})];}).config;
        sessionPool = null;
      }
      // args);
  # Keep only exclusions still active after named entries merge by key.
  activePrefixes = presetScope:
    lib.attrValues
    (lib.filterAttrs (_: prefix: prefix != null) presetScope.excludeModelPrefixes);
  # A direct mkSkill caller enters through the same option type as modules.
  activeExclusionPrefixesForScope = presetScope:
    activePrefixes
    (
      lib.evalModules {
        modules = [
          {
            options.excludeModelPrefixes = opencodeGoPresets.scopeOption;
            config.excludeModelPrefixes = presetScope.excludeModelPrefixes or {};
          }
        ];
      }
    ).config;
  buildSkill = args: let
    opencodeGoCoverageFailures =
      (import ../../lib/opencode-go.nix {
        activeExclusionPrefixes = activeExclusionPrefixesForScope (args.opencodeGo.presetScope or {});
        guidance = args.families;
        inherit lib;
      }).drift;
    techniques = normalizeTechniques args.techniques;
    view = import ../../lib/routing-view.nix {
      inherit lib pools techniques;
      inherit (args) servedModels;
      inherit (args) catalog runtime families models;
      cpaRoutes = args.cpaRoutes or {};
      inherit (args) picker;
      resolvedAgentFiles = args.resolvedAgentFiles or null;
      extraRuntimes = args.extraRuntimes or [];
      manualExternalDelegates = args.manualExternalDelegates or [];
    };
    pools = args.pools or {};
    credentialUsage =
      (lib.evalModules {
        modules = [
          {
            options = {inherit (import ../../lib/reader-options.nix {inherit lib;}) credentialUsage;};
            config.credentialUsage = args.credentialUsage or {};
          }
        ];
      }).config.credentialUsage;
    pacing = import ../../lib/pacing.nix {
      inherit lib credentialUsage techniques;
      inherit (args) runtime;
      cpaRoutes = args.cpaRoutes or {};
    };
    manifest = pkgs.writeText "delegate-routing-${args.runtime}-manifest.json" (builtins.toJSON (
      if args.sessionPool != null && !(builtins.hasAttr args.sessionPool pools)
      then throw "delegate-routing.runtimes.${args.runtime}.sessionPool: unknown pool `${args.sessionPool}`"
      else
        view
        // {
          inherit pacing;
          inherit (args) runtime sessionPool reviewPolicy;
        }
    ));
    helper = (import ../../../../lib/strict-shell-application.nix pkgs) {
      name = "delegate-routing-plan";
      text = ''
        exec ${usagePython}/bin/python3 ${../../scripts}/delegate-routing-plan.py "$@" --manifest ${manifest} --reader-shell ${pkgs.bash}/bin/bash
      '';
    };
    helperCommand = lib.getExe helper;
    helperInstruction = "Runtime: ${args.runtime}; session pool: ${
      if args.sessionPool == null
      then "unknown (buffer cannot be certified)"
      else args.sessionPool
    }. Run `${helperCommand} --role <role> --launch-context <json-path>` before choosing a route. The command collects registered Readers and prints JSON and canonical routing specifications; it never launches delegates. Load the skill for launch-context guidance.";
  in
    assert opencodeGoCoverageFailures == [] || throw "delegate-routing opencode-go presets drift: ${lib.concatStringsSep "; " opencodeGoCoverageFailures}";
      generated.mkTree {
        name = "delegate-routing-${args.runtime}-skill";
        files."SKILL.md" = {
          type = "markdown";
          text = frontmatter.render {
            data = skillData;
            # Prose trimming can discard context; retain the advertised helper
            # as a dependency of the delivered file, including its manifest.
            body =
              builtins.appendContext
              (import ../../lib/render.nix ({inherit lib;} // lib.removeAttrs args ["credentialUsage" "opencodeGo" "picker" "reviewPolicy" "sessionPool"] // {inherit helperInstruction techniques;}))
              (builtins.getContext helperInstruction);
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
      inherit mkSkill mkUsageScript render skills usageScripts;
      inherit (defaults) families models techniques routing skill workflows;
    };
  } ''
    # Full strict mode is required here: stdenv does not set every flag (#909).
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    mkdir -p "$out/fragments" "$out/skills"
    cp ${../../fragments/load-delegate-routing.md} "$out/fragments/load-delegate-routing.md"
    ${lib.concatMapStringsSep "\n" (runtime: "cp -r ${skills.${runtime}} \"$out/skills/${runtime}\"") (builtins.attrNames skills)}
  ''
