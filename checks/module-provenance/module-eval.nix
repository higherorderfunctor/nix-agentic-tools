# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (import ./helpers.nix {inherit lib pkgs harness;}) normalizedPoolNames packagePoolCollisions packagePoolProbeConfigs packagePoolsClean rootPoolClean rootPoolProbeConfig rootPoolSrcRoot rootPoolViolations;
  inherit (harness) aiStubs evalDevenv evalHm harnessNames hmLib mkTest;
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
      lib.all (runtime: rootPoolProbeConfig.ai.${runtime}.enable) harnessNames
      && lib.all
      (program: rootPoolProbeConfig.ai.programs.${program}.enable)
      ["delegate-sizing" "semble" "stacked-workflows"]
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

    # Positive control for every normalized pool at BOTH root and per-runtime
    # scope. The fixture values intentionally use `anything`: this test targets
    # provenance and ownership, not the six independently covered value schemas.
    module-ai-package-pool-collision-guard-fires = mkTest "ai-package-pool-collision-guard-fires" (
      let
        poolOptions = lib.genAttrs normalizedPoolNames (_:
          lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = {};
          });
        probe = lib.evalModules {
          specialArgs = {inherit lib;};
          modules = [
            {options.ai = poolOptions // {claude = poolOptions;};}
            ./fixtures/pool-package-a.nix
            ./fixtures/pool-package-b.nix
          ];
        };
        collisions = packagePoolCollisions probe;
        namesEveryCollision = pool:
          builtins.any (lib.hasInfix "ai.${pool}.shared") collisions
          && builtins.any (lib.hasInfix "ai.claude.${pool}.shared") collisions;
        threw = !(builtins.tryEval (packagePoolsClean "probe" probe)).success;
      in
        builtins.length collisions
        == 12
        && builtins.all namesEveryCollision normalizedPoolNames
        && threw
    );

    # Passing control: two package modules may contribute different keys at the
    # same root and per-runtime scopes.
    module-ai-package-pool-distinct-keys-pass = mkTest "ai-package-pool-distinct-keys-pass" (
      let
        poolOptions = lib.genAttrs normalizedPoolNames (_:
          lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = {};
          });
        probe = lib.evalModules {
          specialArgs = {inherit lib;};
          modules = [
            {options.ai = poolOptions // {claude = poolOptions;};}
            ./fixtures/pool-package-a.nix
            ./fixtures/pool-package-distinct.nix
          ];
        };
      in
        packagePoolCollisions probe == [] && packagePoolsClean "probe" probe
    );

    # Whole-option priorities are filtered before definitionsWithLocations is
    # exposed. The combined evaluation therefore hides package A, while the
    # isolated claim evaluations retain both owners and must still collide.
    module-ai-package-pool-priority-shadow-still-fails = mkTest "ai-package-pool-priority-shadow-still-fails" (
      let
        optionModule.options.ai.skills = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = {};
        };
        packageA = {
          _file = "${rootPoolSrcRoot}/packages/pool-a/default.nix";
          config.ai.skills = lib.mkDefault {shared = "package-a";};
        };
        packageB = {
          _file = "${rootPoolSrcRoot}/packages/pool-b/default.nix";
          config.ai.skills.shared = "package-b";
        };
        mkProbe = modules:
          lib.evalModules {modules = [optionModule] ++ modules;};
        combined = mkProbe [packageA packageB];
        isolated = [
          (mkProbe [packageA])
          (mkProbe [packageB])
        ];
        collisions = packagePoolCollisions isolated;
      in
        packagePoolCollisions combined
        == []
        && builtins.length collisions == 1
        && lib.hasInfix "ai.skills.shared" (builtins.head collisions)
        && !(builtins.tryEval (packagePoolsClean "priority probe" isolated)).success
    );

    # Two files inside one package are one owner, even when the aggregate claim
    # probe observes them in separate evaluations.
    module-ai-package-pool-same-package-files-pass = mkTest "ai-package-pool-same-package-files-pass" (
      let
        optionModule.options.ai.skills = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = {};
        };
        mkProbe = file:
          lib.evalModules {
            modules = [
              optionModule
              {
                _file = file;
                config.ai.skills.shared = "same-package";
              }
            ];
          };
        probes = [
          (mkProbe "${rootPoolSrcRoot}/packages/pool-owner/a.nix")
          (mkProbe "${rootPoolSrcRoot}/packages/pool-owner/b.nix")
        ];
      in
        packagePoolCollisions probes == [] && packagePoolsClean "same-package probe" probes
    );

    # The same key at root and runtime scope is replacement, not a package
    # collision, even when different package owners contribute the two entries.
    module-ai-package-pool-root-runtime-independent = mkTest "ai-package-pool-root-runtime-independent" (
      let
        poolOption = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = {};
        };
        optionModule.options.ai = {
          skills = poolOption;
          claude.skills = poolOption;
        };
        mkProbe = module:
          lib.evalModules {modules = [optionModule module];};
        probes = [
          (mkProbe {
            _file = "${rootPoolSrcRoot}/packages/pool-root/default.nix";
            config.ai.skills.shared = "root";
          })
          (mkProbe {
            _file = "${rootPoolSrcRoot}/packages/pool-runtime/default.nix";
            config.ai.claude.skills.shared = "runtime";
          })
        ];
      in
        packagePoolCollisions probes == [] && packagePoolsClean "scope probe" probes
    );

    # POSITIVE CONTROL. The two root guards pass by finding NOTHING, so a guard
    # that detected nothing at all would look identical to a clean tree. This
    # evaluates a fixture that really does write a root pool and requires the
    # guard to name it — and it goes through `rootPoolClean`, not just
    # `rootPoolViolations`, so the throw path is covered too rather than only the
    # detection path. Delete these three as a set or not at all.
    #
    # Scoped to `sharedOptions.nix` plus the fixture: that module declares every
    # root `ai.*` option, so it is the whole surface under test, and a two-module
    # evaluation cannot pass for an unrelated reason.
    module-ai-root-pool-guard-fires = mkTest "ai-root-pool-guard-fires" (
      let
        probe = lib.evalModules {
          specialArgs = {
            lib = hmLib;
            pkgs = pkgs // {ai = aiStubs;};
          };
          modules = [
            ../../lib/ai/sharedOptions.nix
            ./fixtures/root-pool-writer.nix
          ];
        };
        violations = rootPoolViolations probe;
        # The guard must name THIS option and THIS file — not merely return
        # something non-empty, which a constant would also satisfy.
        named =
          builtins.length violations
          == 1
          && lib.hasInfix "ai.skills" (builtins.head violations)
          && lib.hasInfix "root-pool-writer.nix" (builtins.head violations);
        # And `rootPoolClean` must actually throw on that input. `tryEval` cannot
        # catch a `throw` raised while building the message, so force it.
        threw = !(builtins.tryEval (rootPoolClean "probe" probe)).success;
      in
        named && threw
    );
  };
}
