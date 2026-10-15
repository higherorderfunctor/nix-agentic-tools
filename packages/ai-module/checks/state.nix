{pkgs, ...}: let
  python = pkgs.python3.withPackages (ps: [ps.pyyaml ps.tomlkit]);
in {
  checks.files2-state-runtime = pkgs.runCommandLocal "files2-state-runtime" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${python}/bin/python3 -I ${./state.py} ${../lib/files}/engine.py
    printf 'PASS: files2 state runtime\n' > "$out"
  '';
}
