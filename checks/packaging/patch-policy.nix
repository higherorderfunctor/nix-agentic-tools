# Refuse source bypasses before building; fixtures prove the scanner discriminates.
{pkgs, ...}: let
  python = import ./patch-policy-python.nix pkgs;
in {
  checks.patch-policy = pkgs.runCommand "patch-policy" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${python}/bin/python ${./patch-policy-test.py} ${./patch-policy.py}
    ${python}/bin/python ${./patch-policy.py} ${../..} > "$out"
  '';
}
