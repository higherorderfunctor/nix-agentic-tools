# Stamp, archive, shared-base, publication, failure and hook behavior without CodeQL.
{pkgs, ...}: let
  launcher = import ../../../dev/codeql-lifecycle.nix {inherit pkgs;};
in {
  checks.codeql-lifecycle =
    pkgs.runCommand "codeql-lifecycle" {
      nativeBuildInputs = [pkgs.coreutils pkgs.git pkgs.python3];
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      python3 ${./lifecycle.py} ${../../../dev/scripts/codeql-lifecycle.py} ${launcher}/bin/codeql-lifecycle > "$out" 2>&1
    '';
}
