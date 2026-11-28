{pkgs, ...}: {
  checks.copilot-cli-autoupdate-default = pkgs.runCommand "copilot-cli-autoupdate-default" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    launcher=${pkgs.ai.copilot-cli}/bin/copilot
    upstream=${pkgs.ai.copilot-cli}/libexec/copilot

    # Source the shipped shell wrapper and intercept only its final exec. The
    # vendor binary must not start or try to update during this check.
    check_launch() {
      local actual expected=$1
      actual=$(
        exec() {
          if [[ $1 == -a ]]; then shift 2; fi
          if [[ $1 != "$upstream" ]]; then
            printf 'Copilot launcher delegated to %s, expected %s\n' "$1" "$upstream" >&2
            exit 1
          fi
          # A child only sees exported values: a shell-local default is no good.
          "$BASH" -c 'printf "%s" "''${COPILOT_AUTO_UPDATE-unset}"'
          exit
        }
        source "$launcher"
      )
      if [[ $actual != "$expected" ]]; then
        printf 'Copilot launcher exported %q, expected %s at vendor handoff\n' "$actual" "$expected" >&2
        exit 1
      fi
    }
    unset COPILOT_AUTO_UPDATE
    check_launch false
    export COPILOT_AUTO_UPDATE=true
    check_launch true

    # Upstream-release canary for a removed/renamed key, not a claim about
    # whether the live updater honors the flag.
    if ! ${pkgs.gnugrep}/bin/grep -aqF 'COPILOT_AUTO_UPDATE' "$upstream"; then
      echo 'Vendor binary no longer contains the COPILOT_AUTO_UPDATE key' >&2
      exit 1
    fi
    touch "$out"
  '';
}
