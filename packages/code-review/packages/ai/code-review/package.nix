{pkgs, ...}: let
  inherit (pkgs) lib;
  python = pkgs.python3;
in
  pkgs.stdenvNoCC.mkDerivation {
    pname = "code-review";
    version = "1.0.0";
    src = ../../../src;
    nativeBuildInputs = [pkgs.makeWrapper];
    installPhase = ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      mkdir -p "$out/bin" "$out/share/code-review"
      cp -r LAUNCH.md shared kimchi kiro transport "$out/share/code-review/"
      find "$out/share/code-review" -type d -name tests -exec rm -r {} +
      find "$out/share/code-review" -type f \( -name '*.test.ts' -o -name 'offline-entry.workflow.ts' -o -name '*.example.json' \) -delete
      substituteInPlace "$out/share/code-review/shared/review.py" --replace-fail "['git'," "['${pkgs.git}/bin/git',"
      substituteInPlace "$out/share/code-review/transport/local.py" --replace-fail '@git@' '${pkgs.git}/bin/git'
      substituteInPlace "$out/share/code-review/transport/kimchi.ts" --replace-fail '@python@' '${python}/bin/python3'
      substituteInPlace "$out/share/code-review/transport/prompts/pull.md" "$out/share/code-review/transport/prompts/push.md" --replace-fail '@glab@' '${lib.getExe pkgs.ai.devTools.glab}'
      substituteInPlace "$out/share/code-review/kimchi/workflow.ts" --replace-fail '@python@' '${python}/bin/python3'
      makeWrapper ${python}/bin/python3 "$out/bin/code-review" \
        --add-flags "$out/share/code-review/shared/review.py" \
        --run 'set -euETo pipefail' \
        --run 'shopt -s inherit_errexit 2>/dev/null || :'
      cp -r ${../../../profiles} "$out/share/code-review/profiles"
    '';
    passthru = {
      inherit python;
      glab = pkgs.ai.devTools.glab;
      profiles = {
        kimchi = ../../../profiles/kimchi.json;
        kiro = ../../../profiles/kiro.json;
      };
    };
    meta = {
      description = "Native Kimchi and Kiro code review workflows with a shared local evidence core";
      license = lib.licenses.mit;
      mainProgram = "code-review";
      platforms = lib.platforms.unix;
    };
  }
