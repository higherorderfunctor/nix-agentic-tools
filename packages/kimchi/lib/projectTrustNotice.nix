# `projectPaths`: the launch-relative namespaces of Kimchi's trust-gated
# project files. Kimchi reads them from its exact working directory.
pkgs: projectPaths:
import ../../../lib/strict-shell-application.nix pkgs {
  name = "kimchi-project-trust-notice";
  text = ''
    ${pkgs.python3}/bin/python3 ${./project-trust-notice.py} "$PWD" "''${HOME:-}/.config/kimchi/harness" ${pkgs.lib.escapeShellArgs projectPaths} || :
  '';
}
