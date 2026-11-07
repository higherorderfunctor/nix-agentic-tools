# Transcript notice for the launcher's untrusted-project directory fallback.
{
  directory,
  lib,
  pkgs,
}:
lib.getExe (import ../../../lib/strict-shell-application.nix pkgs {
  name = "delegate-routing-workflow-resume";
  text = ''
    if [[ -z "''${HOME:-}" ]]; then
      exit 0
    fi
    project="$(
      ${pkgs.jq}/bin/jq -ers --arg fallback "$PWD" '
        select(length == 1) | .[0] | select(type == "object")
        | (.cwd // $fallback) | select(type == "string" and length > 0)
      ' 2>/dev/null || :
    )"
    if [[ -z "$project" ]]; then
      exit 0
    fi
    # Keep the trust predicate aligned with claude-code/lib/untrustedProjectDirs.nix.
    if ! ${pkgs.jq}/bin/jq -e --arg p "$project" \
      '.projects[$p].hasTrustDialogAccepted == true' \
      "''${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.claude.json" >/dev/null 2>&1; then
      # systemMessage stays in the transcript. Add additionalContext only if
      # a future consumer needs the model to act on trust, rather than a notice.
      # Preserve the configured spelling in the transcript, including literal ~/ .
      # shellcheck disable=SC2088
      ${pkgs.jq}/bin/jq -cn --arg project "$project" --arg directory ${lib.escapeShellArg directory} '{
        systemMessage: ($project + " is not a trusted Claude Code project; its project settings did not apply. The launcher appended --add-dir " + $directory + " so Workflow resume keeps working.")
      }' || :
    fi
  '';
})
