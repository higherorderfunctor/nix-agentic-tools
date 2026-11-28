# cspell:ignore batchmode sembleignore
# End-to-end module contracts; the shared harness discovers every backend.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  provenance = import ./helpers.nix;
  inherit (provenance {inherit lib harness;}) forwardingHelper normalizedPoolNames packagePoolCollisions packagePoolProbeConfigs packagePoolsClean rootPoolClean rootPoolProbeConfig rootPoolSrcRoot rootPoolViolations;
  optionPaths = import ../../lib/ai/option-paths.nix {inherit lib;};
  inherit (harness) aiStubs checkRows evalDevenv evalHm harnessNames hmLib mkTest rejectsChange;
  poolOption = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = {};
  };
in {
  checks = {
    # ── A1 backstop: no repo module defines a ROOT ai.* option ──
    #
    # One per backend, because the pools are per-`evalModules`: an HM
    # contribution is invisible to the devenv evaluation and vice versa, so a
    # single-backend guard would miss half the tree.
    module-ai-no-root-pool-writes-hm = mkTest "ai-no-root-pool-writes-hm" (
      rootPoolClean "home-manager" (evalHm rootPoolProbeConfig)
    );

    module-ai-no-root-pool-writes-devenv = mkTest "ai-no-root-pool-writes-devenv" (
      rootPoolClean "devenv" (evalDevenv rootPoolProbeConfig)
    );

    # The provenance probe must retain runtime enables while adding program
    # enables. A shallow merge here silently makes runtime-gated callbacks
    # unreachable and turns the guard into a false negative.
    module-ai-root-pool-probe-retains-runtime-enables = mkTest "ai-root-pool-probe-retains-runtime-enables" (
      checkRows "root pool probe enables" (
        lib.listToAttrs (
          map (runtime:
            lib.nameValuePair "runtime ${runtime} remains enabled"
            (lib.attrByPath (optionPaths.enable runtime) false rootPoolProbeConfig == true))
          harnessNames
          ++ map (program:
            lib.nameValuePair "program ${program} is enabled"
            ((rootPoolProbeConfig.ai.programs.${program}.enable or false) == true))
          ["delegate-routing" "peer-communication" "semble" "stacked-workflows"]
        )
      )
    );

    # Package ownership is checked independently per scope. These production
    # evaluations cover every imported package module in both backends. The
    # isolated activation probes preserve claims that another package could hide
    # with whole-option priority before definitionsWithLocations is exposed.
    module-ai-no-package-pool-collisions-hm = mkTest "ai-no-package-pool-collisions-hm" (
      packagePoolsClean "home-manager" (map evalHm packagePoolProbeConfigs)
    );

    module-ai-no-package-pool-collisions-devenv = mkTest "ai-no-package-pool-collisions-devenv" (
      packagePoolsClean "devenv" (map evalDevenv packagePoolProbeConfigs)
    );

    module-ai-package-pool-collision-guard-fires = mkTest "ai-package-pool-collision-guard-fires" (
      let
        # Fixture values intentionally use `anything`: this test targets
        # provenance and ownership, not the independently covered value schemas.
        poolNames = normalizedPoolNames;
        pools = lib.genAttrs poolNames (_: poolOption);
        fixtureClaims = key: value: let
          claims = lib.genAttrs poolNames (_: {${key} = value;});
        in
          claims // {claude = claims;};
        probeWithKey = fixturePackageBKey: modules:
          lib.evalModules {
            specialArgs = {inherit fixtureClaims fixturePackageBKey;};
            modules = [{options.ai = pools // {claude = pools;};}] ++ modules;
          };
        probe = probeWithKey "shared";
        claim = ownerFile: ai: {
          _file = "${rootPoolSrcRoot}/packages/${ownerFile}.nix";
          config = {inherit ai;};
        };
        fixtureA = ./fixtures/pool-package-a.nix;
        fixtureB = ./fixtures/pool-package-b.nix;
        consumer = probe [
          fixtureA
          {
            ai.skills = {
              inline = "consumer";
              shared = "package-a";
            };
          }
        ];
        fixtures = [fixtureA fixtureB];
        distinct = probeWithKey "distinct" fixtures;
        overlapping = probe fixtures;
        isolate = map (module: probe [module]);

        # Give the real probe builder two owner switches. In the combined
        # evaluation B's ordinary definition hides A's whole-option default;
        # only evaluating the switches separately can recover A's provenance.
        packageA = claim "pool-a/default" {skills = lib.mkDefault {shared = "package-a";};};
        packageB = claim "pool-b/default" {skills.shared = "package-b";};
        priorityHarness =
          harness
          // {
            harnessNames = ["claude"];
            testing.moduleProbes = [{probe.a = true;} {probe.b = true;}];
          };
        priorityProbes = provenance {
          inherit lib;
          harness = priorityHarness;
        };
        evalPriority = config:
          probe [
            config
            ({config, ...}: {
              options = {
                ai.claude.enable = lib.mkEnableOption "the probe runtime";
                probe.a = lib.mkEnableOption "package A's claim";
                probe.b = lib.mkEnableOption "package B's claim";
              };
              imports = [
                (packageA // {config = lib.mkIf config.probe.a packageA.config;})
                (packageB // {config = lib.mkIf config.probe.b packageB.config;})
              ];
            })
          ];
        combined = evalPriority priorityProbes.rootPoolProbeConfig;
        priorityEvaluations = map evalPriority priorityProbes.packagePoolProbeConfigs;
        fixtureOwners = [(toString fixtureA) (toString fixtureB)];
        # Names and attribution are the contract, not definition order.
        collisionsByKey = evaluated:
          lib.sort (a: b: a.key < b.key) (map (diagnostic: let
            parts = lib.splitString " <- " diagnostic;
          in {
            key = builtins.head parts;
            files = lib.sort builtins.lessThan (lib.splitString ", " (builtins.elemAt parts 1));
          }) (packagePoolCollisions evaluated));
      in
        checkRows "package pool ownership" {
          "consumer inline keys do not become a second package owner" =
            consumer.config.ai.skills
            == {
              inline = "consumer";
              shared = "package-a";
            }
            && packagePoolsClean "inline consumer" consumer;
          "files under one package count as one owner" = let
            probes = isolate [
              (claim "pool-owner/a" {skills.shared = "same-package";})
              (claim "pool-owner/b" {skills.shared = "same-package";})
            ];
          in
            map (evaluated: evaluated.config.ai.skills.shared) probes
            == ["same-package" "same-package"]
            && packagePoolCollisions probes == [];
          "isolated evaluations reject a claim shadowed by priority in the combined tree" =
            combined.config.ai.skills
            == {shared = "package-b";}
            && collisionsByKey priorityEvaluations
            == [
              {
                key = "ai.skills.shared";
                files = [packageA._file packageB._file];
              }
            ]
            && rejectsChange (packagePoolsClean "priority probe") {
              valid = combined;
              invalid = priorityEvaluations;
              expected = true;
            };
          "same keys across root and runtime scopes are independent" = let
            root = probe [(claim "pool-root/default" {skills.shared = "root";})];
            runtime = probe [(claim "pool-runtime/default" {claude.skills.shared = "runtime";})];
          in
            root.config.ai.skills
            == {shared = "root";}
            && runtime.config.ai.claude.skills == {shared = "runtime";}
            && packagePoolCollisions [root runtime] == [];
          "unrelated keys pass but the same key in any one pool and scope is rejected" =
            distinct.config.ai.skills
            == {
              distinct = "package-b";
              shared = "package-a";
            }
            && collisionsByKey overlapping
            == map (key: {
              inherit key;
              files = fixtureOwners;
            }) [
              "ai.agents.shared"
              "ai.claude.agents.shared"
              "ai.claude.environmentVariables.shared"
              "ai.claude.mcpServers.shared"
              "ai.claude.rules.shared"
              "ai.claude.skills.shared"
              "ai.environmentVariables.shared"
              "ai.mcpServers.shared"
              "ai.rules.shared"
              "ai.skills.shared"
            ]
            && rejectsChange (packagePoolsClean "overlapping keys") {
              valid = distinct;
              invalid = overlapping;
              expected = true;
            };
        }
    );

    # The root guards pass by finding nothing, so a guard that detects nothing
    # also looks like a clean tree. Scope this control to the real declaring
    # module and the fixture so the guard cannot fail for an unrelated reason.
    # Delete this control and the two `module-ai-no-root-pool-writes-*` guards
    # as a set or not at all.
    module-ai-root-pool-guard-fires = mkTest "ai-root-pool-guard-fires" (
      let
        writer = ./fixtures/root-pool-writer.nix;
        probe = module:
          lib.evalModules {
            specialArgs = {
              lib = hmLib;
              pkgs = pkgs // {ai = aiStubs;};
            };
            modules = [../../lib/ai/sharedOptions.nix module];
          };
        consumer = probe (import writer);
        repoModule = probe writer;
      in
        checkRows "root pool ownership" {
          "a repository module writing ai.skills is rejected and named" =
            rootPoolViolations repoModule
            == ["ai.skills <- ${toString writer}"]
            && rejectsChange (rootPoolClean "root writer probe") {
              valid = consumer;
              invalid = repoModule;
              expected = true;
            };
        }
    );

    # The layer-1 exemption covers the forwarded options from the helper's file
    # only. Read actual provenance so an owner forwarding nothing cannot pass.
    module-ai-root-pool-forwarding-exempt = mkTest "ai-root-pool-forwarding-exempt" (
      let
        probe = modules:
          lib.evalModules {
            specialArgs = {inherit pkgs;};
            modules =
              [
                ../../packages/ai-module/modules/common.nix
                {options.ai.skills = poolOption;}
              ]
              ++ modules;
          };
        owner = probe [
          (import ../../packages/ai-module/lib/runtime.nix {
            enabled = true;
            name = "probe";
          })
          {
            ai.probe = {
              activation.probe.command = "true";
              files."probe.txt".content.text = "probe";
              legacyLedgers = [
                {
                  codec = "dir";
                  ledger = "materialize/probe.manifest";
                  path = ".";
                }
              ];
              services.probe.command = ["/bin/probe"];
            };
          }
        ];
        directWriter = ./fixtures/root-layer-writer.nix;
        direct = probe [directWriter];
        impostor = probe [
          {
            _file = forwardingHelper;
            config.ai.skills.probe = "impostor";
          }
        ];
        forwarded = lib.filterAttrs (_: option:
          lib.isOption option
          && lib.any (definition: toString definition.file == forwardingHelper) option.definitionsWithLocations)
        owner.options.ai;
      in
        checkRows "layer-1 forwarding provenance" {
          "another file writing forwarded options directly is rejected and named" =
            rootPoolViolations direct
            == [
              "ai.activation <- ${toString directWriter}"
              "ai.claims <- ${toString directWriter}"
              "ai.files <- ${toString directWriter}"
              "ai.legacyLedgers <- ${toString directWriter}"
              "ai.services <- ${toString directWriter}"
            ]
            && rejectsChange (rootPoolClean "owner forwarding probe") {
              valid = owner;
              invalid = direct;
              expected = true;
            };
          "the helper is not exempt for ai.skills" =
            rootPoolViolations impostor
            == ["ai.skills <- ${forwardingHelper}"]
            && rejectsChange (rootPoolClean "owner forwarding probe") {
              valid = owner;
              invalid = impostor;
              expected = true;
            };
          "the helper writes exactly the exempt layer-1 options" =
            builtins.attrNames forwarded
            == ["activation" "claims" "files" "legacyLedgers" "services"];
        }
    );
  };
}
