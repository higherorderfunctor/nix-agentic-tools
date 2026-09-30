{
  lib,
  pkgs,
  ...
}: let
  # The scenarios read only these two owners' Markdown and Nix, so a change
  # elsewhere in the repository does not rerun them.
  source = lib.fileset.toSource {
    root = ../../..;
    fileset = lib.fileset.unions [
      ../../../packages/git-branchless
      ../../../packages/stacked-workflows
    ];
  };
in {
  checks.stacked-workflows-scenarios =
    pkgs.runCommand "stacked-workflows-scenarios" {
      nativeBuildInputs = [
        pkgs.ai.gitTools.git-absorb
        pkgs.ai.gitTools.git-branchless
        pkgs.ai.gitTools.git-revise
        pkgs.bash
        pkgs.git
        pkgs.python3
      ];
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      export HOME="$TMPDIR/home"
      export XDG_CONFIG_HOME="$HOME/.config"
      export GIT_CONFIG_NOSYSTEM=1
      mkdir -p "$XDG_CONFIG_HOME"
      python3 ${./scenario-tests}/scenarios.py \
        --source-dir ${source} --output "$out"
    '';
}
