# Refuse source bypasses before building; fixtures prove the scanner discriminates.
{pkgs, ...}: {
  checks.patch-policy = pkgs.runCommand "patch-policy" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${pkgs.python3}/bin/python ${./patch-policy-test.py} ${./patch-policy.py}
    ${pkgs.python3}/bin/python ${./patch-policy.py} ${../..} > "$out"
  '';
}
