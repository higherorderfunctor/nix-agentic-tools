{pkgs, ...}: let
  python = pkgs.python3.withPackages (ps: [ps.pyyaml ps.tomlkit]);
in {
  checks.ai-module-files-state-runtime = pkgs.runCommandLocal "ai-module-files-state-runtime" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${python}/bin/python3 -I ${./state.py} ${../lib/files}/engine.py
    printf 'PASS: files state runtime\n' > "$out"
  '';
}
