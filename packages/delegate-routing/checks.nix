{
  config,
  harness,
  lib,
  pkgs,
  ...
}: let
  cases = import ./eval/cases.nix {inherit harness lib pkgs;};
  fixtures = pkgs.writeText "delegate-routing-cases.json" (builtins.toJSON cases);
in {
  checks = {
    # Rejects capped/idle shortcuts, paced rolling gates, backing-gated weights,
    # discarded zero routes and reference dependence on production arithmetic.
    delegate-routing-allowance-ranking =
      pkgs.runCommand "delegate-routing-allowance-ranking" {
        nativeBuildInputs = [pkgs.python3];
        inherit (config.checks.delegate-routing-observation-command) manifest;
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        export ALLOWANCE_TEST_ROOT="$TMPDIR"
        python3 -I ${./checks/pacing}/test_allowance.py ${./scripts} "$manifest"
        touch "$out"
      '';

    # Validates every case and renders its fixture and launch plan with no
    # harness on PATH and no login: the suite's --dry-run, nothing launched.
    delegate-routing-eval-structure =
      pkgs.runCommand "delegate-routing-eval-structure" {
        nativeBuildInputs = [pkgs.diffutils pkgs.git pkgs.python3];
        passthru = {inherit cases;};
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        export HOME="$TMPDIR/home"
        python ${./eval}/test_suite.py
        # Templated Kiro probe configs must stay byte-identical to their committed paths.
        python ${./probes/delegates/kiro}/rules.py --check > "$TMPDIR/kiro-rules.log"
        python ${./eval}/suite.py --dry-run --fixtures ${fixtures} --out "$TMPDIR/suite" > "$TMPDIR/dry-run.log"
        touch "$out"
      '';
    # Rejects independent pool registrations, duplicate Reader calls, live
    # credential use, provider-as-pool joins and missing delivery backends.
    delegate-routing-observation-command = let
      fixture = builtins.fromJSON (builtins.readFile ./checks/pacing/reader-snapshots.json);
      bindings = {
        anthropic-api = {
          adapter = "anthropic-spend";
          kind = "metered";
        };
        claude = {
          adapter = "claude-subscription";
          kind = "subscription";
        };
        codex = {
          adapter = "codex-subscription";
          kind = "subscription";
        };
        opencode-go = {
          adapter = "opencode-go";
          kind = "subscription";
        };
        z-ai = {
          adapter = "zai";
          kind = "subscription";
        };
      };
      definitions =
        lib.mapAttrs (pool: binding: {
          credentials.${binding.kind} = {
            auth = "apiKey";
            binding = "fixture-${pool}";
          };
          models = lib.unique (lib.concatMap (limit: limit.models) (builtins.attrValues fixture.pools.${pool}.limits));
          usage.${binding.kind} = {
            inherit (binding) adapter;
            runtime = "codex";
            technique = pool;
          };
        })
        bindings;
      catalog = (import ../ai-module/lib/catalog/resolve.nix {inherit lib;}).resolve {
        pools = definitions;
        runtimes = {
          inspection.pools = ["anthropic-api" "codex" "opencode-go" "z-ai"];
          subscription.pools = ["claude"];
        };
      };
      observationArgs = {
        inherit catalog;
        poolDefinitions = definitions;
        pacing.pools = {
          claude.weight = 0.5;
          codex.weight = 1.5;
        };
        techniques.codex =
          lib.mapAttrs (pool: _: {
            command = "fake-reader ${pool}";
            enable = true;
            kind = "usage";
          })
          bindings;
        budgets.anthropic-api.window = {
          limit = 200;
          resetDay = 1;
          unit = "USD";
        };
      };
      project = args: import ./lib/pacing.nix {inherit lib;} args;
      manifests = project observationArgs;
      refuses = overrides: !(builtins.tryEval (builtins.deepSeq (project (observationArgs // overrides)) true)).success;
      rejections = {
        disabled-technique = refuses {
          techniques.codex = lib.genAttrs (builtins.attrNames bindings) (_: {
            command = "fake-reader";
            enable = false;
            kind = "usage";
          });
        };
        duplicate-registration = refuses {
          budgets.codex.usage = {
            runtime = "codex";
            technique = "codex";
          };
        };
        missing-api-budget = refuses {budgets = {};};
        missing-association = refuses {poolDefinitions = definitions // {codex = definitions.codex // {usage = {};};};};
        missing-credential-kind = refuses {poolDefinitions = definitions // {codex = definitions.codex // {credentials = {};};};};
        multiple-billing-kinds = refuses {
          poolDefinitions =
            definitions
            // {
              codex =
                definitions.codex
                // {
                  credentials = definitions.codex.credentials // {metered = definitions.codex.credentials.subscription;};
                  usage = definitions.codex.usage // {metered = definitions.codex.usage.subscription;};
                };
            };
        };
        negative-weight = refuses {pacing.pools.codex.weight = -1;};
        retired-policy = refuses {pacing.pools.codex.resetPolicy = "use";};
        unknown-weight-pool = refuses {pacing.pools.absent.weight = 1;};
        wrong-billing-kind = refuses {poolDefinitions = definitions // {codex = definitions.codex // {usage.subscription = definitions.codex.usage.subscription // {adapter = "anthropic-spend";};};};};
        zero-api-budget = refuses {
          budgets.anthropic-api.window = {
            limit = 0;
            resetDay = 1;
            unit = "USD";
          };
        };
        zero-weight = refuses {pacing.pools.codex.weight = 0;};
      };
    in
      assert lib.all (name: rejections.${name} || throw "observation registration accepted ${name}") (builtins.attrNames rejections);
        pkgs.runCommand "delegate-routing-observation-command" {
          nativeBuildInputs = [pkgs.bash pkgs.python3];
          refused = lib.concatStringsSep ", " (builtins.attrNames rejections);
          manifest = pkgs.writeText "observation-fixture.json" (builtins.toJSON manifests);
          deliveryDevenv = config.checks.module-delegate-routing-devenv-observation-command;
          deliveryHm = config.checks.module-delegate-routing-hm-observation-command;
        } ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          echo "PASS: catalog registration refuses $refused"
          export OBSERVATION_TEST_ROOT="$TMPDIR"
          python3 -I ${./checks/pacing}/test_observation_command.py ${./scripts} "$manifest"
          echo "PASS: HM and devenv observation delivery dependencies built: $deliveryHm $deliveryDevenv"
          touch "$out"
        '';
    # Rejects simplified captures, implicit clocks, guessed scopes/enforcement
    # and absent extras presented as measured zero.
    delegate-routing-observation-normalize =
      pkgs.runCommand "delegate-routing-observation-normalize" {
        nativeBuildInputs = [pkgs.python3];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        python3 -I ${./checks/pacing}/test_observations.py ${./scripts}
        touch "$out"
      '';
    # Every model owned by Go research guidance belongs to exactly one preset;
    # native guidance families do not restrict the shared served-offer inventory.
    delegate-routing-opencode-go-presets = let
      inherit (import ./lib/opencode-go.nix {inherit lib;}) drift;
    in
      harness.mkTest "delegate-routing-opencode-go-presets" (
        drift == [] || throw "delegate-routing opencode-go presets drift from the pinned catalog: ${lib.concatStringsSep "; " drift}"
      );
    delegate-routing-plan-runtime =
      pkgs.runCommand "delegate-routing-plan-runtime" {
        nativeBuildInputs = [pkgs.bash pkgs.python3];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        python3 ${./checks/routing-plan-runtime.py} ${./scripts/delegate-routing-plan.py} ${./checks/fixtures/routing-readers.json} ${./checks/fixtures/codex-models-cache.json}
        touch "$out"
      '';
    delegate-routing-usage-runtime =
      pkgs.runCommand "delegate-routing-usage-runtime" {
        nativeBuildInputs = [pkgs.bash pkgs.coreutils pkgs.curl pkgs.jq pkgs.python3];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        python ${./checks/usage-runtime.py} ${./scripts}
        touch "$out"
      '';
  };
  imports = [./checks/module-eval.nix ./checks/reminder-runtime.nix ./checks/workflow-resume-runtime.nix];
  testing.moduleProbes = [
    {
      ai = {
        # The provenance helpers enable every runtime, and delegate-routing
        # asserts each enabled one selects a family. These selections only
        # keep the probe config valid.
        programs.delegate-routing = {
          enable = true;
          runtimes = {
            kimchi.models = [{vendors = ["anthropic"];}];
            kiro.models = [{vendors = ["anthropic"];}];
          };
        };
      };
    }
  ];
}
