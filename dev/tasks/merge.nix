# dev/tasks/merge.nix — local PR-merge action. Needs network + gh auth,
# so it lives outside the CI sandbox / flake checks (like check.nix).
#
# Logic lives in dev/scripts/merge-update-prs.sh so it is runnable with
# or without devenv/AI. This task is a thin wrapper.
_: let
  bashPreamble = ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
  '';
in {
  tasks = {
    "pr:merge-updates" = {
      description = "Squash-merge passing dependency-update PRs (single pass; gh, authed). MERGE_DRY_RUN=1 to preview.";
      exec = ''
        ${bashPreamble}
        bash dev/scripts/merge-update-prs.sh "$@"
      '';
    };
  };
}
