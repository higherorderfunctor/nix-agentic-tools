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
  # Run the published recipes against real Git tools in CI, not just the
  # extractor: a valid shell block can still mutate the wrong stack.
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
      python3 ${./scenario-tests}/scenarios.py \
        --source-dir ${source} --output "$out"
    '';
}
