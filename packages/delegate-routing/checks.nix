{
  harness,
  lib,
  pkgs,
  ...
}: let
  cases = import ./eval/cases.nix {inherit harness lib;};
  fixtures = pkgs.writeText "delegate-routing-eval-cases.json" (builtins.toJSON cases);
  python = pkgs.python3.withPackages (packages: [packages.jsonschema]);
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
