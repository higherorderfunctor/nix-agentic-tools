pkgs:
import ../../../lib/strict-shell-application.nix pkgs {
  name = "codex-project-trust";
  text = ''
    ${pkgs.python3}/bin/python3 ${./project-trust.py} "$1" "''${CODEX_HOME:-''${HOME:-}/.codex}/config.toml" ${pkgs.git}/bin/git || printf 'unknown\n'
  '';
}
