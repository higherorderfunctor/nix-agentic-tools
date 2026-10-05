{
  harness,
  lib,
  pkgs,
  ...
}: let
  cases = import ./eval/cases.nix {inherit harness lib;};
  fixtures = pkgs.writeText "delegate-routing-eval-cases.json" (builtins.toJSON cases);
  python = pkgs.python3.withPackages (packages: [packages.jsonschema]);
  vendorCases = import ./eval/vendor-cases.nix {inherit harness lib pkgs;};
  vendorFixtures = pkgs.writeText "delegate-routing-vendor-cases.json" (builtins.toJSON vendorCases);
in {
  checks.delegate-routing-eval-structure =
    pkgs.runCommand "delegate-routing-eval-structure" {
      nativeBuildInputs = [python];
      passthru = {inherit cases;};
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      python ${./eval}/run.py --validate-fixtures --fixtures ${fixtures}
      touch "$out"
    '';
  checks.delegate-routing-vendor-structure =
    pkgs.runCommand "delegate-routing-vendor-structure" {
      nativeBuildInputs = [python];
      passthru.cases = vendorCases;
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      python ${./eval}/run.py --set vendor --validate-fixtures --fixtures ${vendorFixtures}
      python ${./eval}/run.py --set vendor --render-only --fixtures ${vendorFixtures} --repeat 1 --out "$TMPDIR/vendor-render" > "$TMPDIR/vendor-render.log"
      touch "$out"
    '';
  imports = [./checks/module-eval.nix];
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
