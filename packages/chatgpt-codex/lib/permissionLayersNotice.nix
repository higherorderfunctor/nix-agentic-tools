pkgs:
import ../../../lib/strict-shell-application.nix pkgs {
  name = "codex-permission-layers-notice";
  text = ''
    ${pkgs.python3}/bin/python3 ${./permission-layers-notice.py} "$1" "''${CODEX_HOME:-''${HOME:-}/.codex}/config.toml" || :
  '';
}
