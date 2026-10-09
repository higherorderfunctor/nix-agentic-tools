# `projectPaths`: the launch-relative namespaces of Kimchi's trust-gated
# project files. Kimchi reads them from its exact working directory.
# `userHarnessDir`: the user harness holding trust.json, relative to HOME;
# Home Manager passes its configDir's harness.
# `userPermissionsDir`: Kimchi's fixed user permissions directory, relative to
# HOME; user scope even when configDir moves the harness.
pkgs: {
  projectPaths,
  userHarnessDir ? userPermissionsDir,
  userPermissionsDir,
}:
import ../../../lib/strict-shell-application.nix pkgs {
  name = "kimchi-project-trust-notice";
  text = ''
    ${pkgs.python3}/bin/python3 ${./project-trust-notice.py} "$PWD" "''${HOME:-}"/${pkgs.lib.escapeShellArg userHarnessDir} "''${HOME:-}"/${pkgs.lib.escapeShellArg userPermissionsDir} ${pkgs.lib.escapeShellArgs projectPaths} || :
  '';
}
