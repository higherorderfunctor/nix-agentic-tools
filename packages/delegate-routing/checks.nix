{
  harness,
  lib,
  pkgs,
  ...
}: let
  cases = import ./eval/cases.nix {inherit harness lib pkgs;};
  fixtures = pkgs.writeText "delegate-routing-cases.json" (builtins.toJSON cases);
in {
  checks = {
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
    # Extracted-data property: rejects missing or duplicate fit ownership,
    # including models previously hidden by fixed prefix exclusions.
    delegate-routing-opencode-go-presets = let
      inherit (import ./lib/opencode-go.nix {inherit lib;}) drift;
    in
      harness.mkTest "delegate-routing-opencode-go-presets" (
        drift == [] || throw "delegate-routing opencode-go presets drift from the pinned catalog: ${lib.concatStringsSep "; " drift}"
      );
    # Synthetic properties: reject hidden prefix policy, ignored scope,
    # ambiguous/incomplete guidance, and a stale-preset removal snapshot.
    delegate-routing-opencode-go-scope = let
      fit = {
        avoidFor = "unverified output";
        defaultEffort = null;
        effort = "no effort pin";
        match = "fixture-*";
        useFor = "bounded fixture tasks";
      };
      check = args: (import ./lib/opencode-go.nix ({inherit lib;} // args)).drift;
      fixture = {
        guidance.example.test = fit;
        modelIds = ["fixture-model"];
      };
    in
      harness.mkTest "delegate-routing-opencode-go-scope" (
        check fixture
        == []
        && check (fixture // {modelIds = [];}) == []
        && check (fixture // {modelIds = ["claude-future" "glm-future" "gpt-future"];})
        == [
          "catalog model `claude-future` matches no preset"
          "catalog model `glm-future` matches no preset"
          "catalog model `gpt-future` matches no preset"
        ]
        && check (fixture
          // {
            modelIds = ["fixture-model" "other-model"];
            presetScope.excludeModelPrefixes = ["OTHER-"];
          })
        == []
        && check (fixture
          // {
            modelIds = ["fixture-model" "new-model" "other-model"];
            presetScope.excludeModelPrefixes = ["other-"];
          })
        == ["catalog model `new-model` matches no preset"]
        && check (fixture
          // {
            guidance.example = {
              duplicate = fit;
              test = fit;
            };
          })
        == ["catalog model `fixture-model` matches several presets: example.duplicate, example.test"]
        && check (fixture // {guidance.example.test = fit // {useFor = "";};}) == ["catalog model `fixture-model` lacks fit guidance"]
        && lib.all (prefixes: !(builtins.tryEval (builtins.deepSeq (check (fixture // {presetScope.excludeModelPrefixes = prefixes;})) true)).success) [[""] [1] "fixture-"]
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
  imports = [./checks/catalog-routes.nix ./checks/module-eval.nix ./checks/reminder-runtime.nix ./checks/workflow-resume-runtime.nix];
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
