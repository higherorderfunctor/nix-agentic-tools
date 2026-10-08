pkgs:
import ../../../lib/strict-shell-application.nix pkgs {
  name = "kimchi-project-trust-notice";
  text = ''
    directory=$1
    shift
    ${pkgs.python3}/bin/python3 ${./project-trust-notice.py} "$directory" "''${HOME:-}/.config/kimchi/harness" "$@" || :
  '';
}
