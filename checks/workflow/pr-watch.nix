# Offline test for the pr-review-loop skill's pr-watch.sh: the real script
# against a stub gh serving fixture JSON. See pr-watch.test.sh for the cases.
{pkgs, ...}: {
  checks.pr-watch =
    pkgs.runCommand "pr-watch-check" {
      nativeBuildInputs = [pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.jq pkgs.shellcheck];
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      script=${../../dev/skills/pr-review-loop/scripts/pr-watch.sh}
      test -x "$script"
      shellcheck --shell=bash "$script" ${./pr-watch.test.sh}
      bash ${./pr-watch.test.sh} "$script"
      touch "$out"
    '';
}
