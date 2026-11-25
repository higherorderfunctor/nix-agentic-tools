{pkgs, ...}: {
  checks.darwin-cache-gate-filter =
    pkgs.runCommand "darwin-cache-gate-filter-check" {
      nativeBuildInputs = [pkgs.python3];
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      python3 -I ${./darwin-cache-gate-test.py} ${../../dev/scripts/darwin-cache-gate.py} ${./fixtures/darwin-cache-gate}
      touch "$out"
    '';
}
