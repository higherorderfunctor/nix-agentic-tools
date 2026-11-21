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
    # Handwritten saved captures and properties reject clipped pace and unreadable evidence.
    delegate-routing-allowance-ranking =
      pkgs.runCommand "delegate-routing-allowance-ranking" {
        nativeBuildInputs = [(pkgs.python3.withPackages (ps: [ps.hypothesis ps.pydantic]))];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        export HYPOTHESIS_STORAGE_DIRECTORY="$TMPDIR/hypothesis"
        python3 -I -B ${./checks/pacing}/test_allowance.py ${./scripts} ${./checks/pacing/ranking-cases}
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
    # Saved captures retain routes and measured allowance when another component fails.
    delegate-routing-observation-normalize =
      pkgs.runCommand "delegate-routing-observation-normalize" {
        nativeBuildInputs = [(pkgs.python3.withPackages (ps: [ps.hypothesis ps.pydantic]))];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        export HYPOTHESIS_STORAGE_DIRECTORY="$TMPDIR/hypothesis"
        python3 -I -B ${./checks/pacing}/run_cases.py ${./scripts} ${./checks/pacing/cases}
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
    # Synthetic properties: ignored scope, case-insensitive matching, and
    # ambiguous or incomplete guidance are distinct failures.
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
      cases = {
        default-scope-keeps-all-models = {
          input.modelIds = ["claude-future" "glm-future" "gpt-future"];
          expected = [
            "catalog model `claude-future` matches no preset"
            "catalog model `glm-future` matches no preset"
            "catalog model `gpt-future` matches no preset"
          ];
        };
        exclusions-match-case-insensitively = {
          input =
            fixture
            // {
              activeExclusionPrefixes = ["OTHER-"];
              modelIds = ["fixture-model" "other-model"];
            };
          expected = [];
        };
        exclusions-preserve-unmatched-coverage = {
          input =
            fixture
            // {
              activeExclusionPrefixes = ["other-"];
              modelIds = ["fixture-model" "new-model" "other-model"];
            };
          expected = ["catalog model `new-model` matches no preset"];
        };
        incomplete-guidance-is-reported = {
          input = fixture // {guidance.example.test = fit // {useFor = "";};};
          expected = ["catalog model `fixture-model` lacks fit guidance"];
        };
        overlapping-presets-are-reported = {
          input =
            fixture
            // {
              guidance.example = {
                duplicate = fit;
                test = fit;
              };
            };
          expected = ["catalog model `fixture-model` matches several presets: example.duplicate, example.test"];
        };
      };
    in
      harness.mkTest "delegate-routing-opencode-go-scope" (
        lib.all (name:
          check cases.${name}.input
          == cases.${name}.expected
          || throw "delegate-routing opencode-go scope case `${name}` failed") (builtins.attrNames cases)
      );
    delegate-routing-plan-runtime =
      pkgs.runCommand "delegate-routing-plan-runtime" {
        nativeBuildInputs = [pkgs.bash (pkgs.python3.withPackages (ps: [ps.hypothesis ps.pydantic ps.urllib3]))];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        python3 -I -B ${./checks/usage/runner}/test_runner.py ${./scripts}
        python3 -I -B ${./checks/usage/transport}/test_transport.py ${./scripts}
        python3 ${./checks/routing-plan-runtime.py} ${./scripts}/delegate-routing-plan.py ${./checks/fixtures/routing-readers.json} ${./checks/fixtures/codex-models-cache.json}
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
