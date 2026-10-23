# The checkout owns source/config, even after a pull; the store supplies tools.
{pkgs}:
import ../lib/strict-shell-application.nix pkgs {
  name = "codeql-lifecycle";
  runtimeInputs = [pkgs.coreutils pkgs.git pkgs.nix pkgs.python3];
  text = ''
    launch() {
      root="$(git rev-parse --show-toplevel)" || return
      exec ${pkgs.python3}/bin/python3 "$root/dev/scripts/codeql-lifecycle.py" "$@"
    }
    if [[ "''${1-}" == hook ]]; then
      # The destination branch may predate the script; Git stays advisory.
      (launch "$@") || :
    else
      launch "$@"
    fi
  '';
}
