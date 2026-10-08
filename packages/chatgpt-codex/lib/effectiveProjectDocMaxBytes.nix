pkgs:
import ../../../lib/strict-shell-application.nix pkgs {
  name = "codex-effective-project-doc-max-bytes";
  text = ''
    exec ${pkgs.python3}/bin/python3 ${./effectiveProjectDocMaxBytes.py} ${pkgs.git}/bin/git "$@"
  '';
}
