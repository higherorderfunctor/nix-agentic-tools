{pkgs, ...}: {
  imports = [./checks/kimchi.nix ./checks/module-eval.nix];
  checks = {
    code-review-adapter =
      pkgs.runCommand "code-review-adapter" {
        nativeBuildInputs = [pkgs.python3];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        export CODE_REVIEW_PAYLOAD=${pkgs.ai.code-review}/share/code-review
        python ${./checks/test_adapter.py}
        touch "$out"
      '';
    code-review-core =
      pkgs.runCommand "code-review-core" {
        nativeBuildInputs = [pkgs.git pkgs.python3];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        export HOME="$TMPDIR/home"
        export CODE_REVIEW_SHARED=${pkgs.ai.code-review}/share/code-review/shared
        python ${./src/shared/tests/test_review.py}
        touch "$out"
      '';
    code-review-transport =
      pkgs.runCommand "code-review-transport" {
        nativeBuildInputs = [pkgs.git pkgs.python3];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        export HOME="$TMPDIR/home"
        export CODE_REVIEW_TRANSPORT=${pkgs.ai.code-review}/share/code-review/transport
        python -m unittest discover -s ${./src/transport/tests}
        touch "$out"
      '';
  };
}
