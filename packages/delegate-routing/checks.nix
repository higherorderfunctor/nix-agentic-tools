{
  harness,
  lib,
  pkgs,
  ...
}: let
  cases = import ./eval/cases.nix {inherit harness lib pkgs;};
  fixtures = pkgs.writeText "delegate-routing-cases.json" (builtins.toJSON cases);
in {
  # Validates every case and renders its fixture and launch plan with no
  # harness on PATH and no login: the suite's --dry-run, nothing launched.
  checks.delegate-routing-eval-structure =
    pkgs.runCommand "delegate-routing-eval-structure" {
      nativeBuildInputs = [pkgs.git pkgs.python3];
      passthru = {inherit cases;};
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      export HOME="$TMPDIR/home"
      python ${./eval}/suite.py --dry-run --fixtures ${fixtures} --out "$TMPDIR/suite" > "$TMPDIR/dry-run.log"
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
