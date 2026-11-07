# Launcher argv fallback for directories delivered through project settings.
{
  lib,
  pkgs,
}: {
  flags = dirs:
    lib.optional (dirs != []) "--run ${lib.escapeShellArg ''
      if [[ -n "''${HOME:-}" ]]; then
        # Keep the trust predicate aligned with delegate-routing/lib/workflow-resume.nix.
        if ! ${pkgs.jq}/bin/jq -e --arg p "$PWD" \
          '.projects[$p].hasTrustDialogAccepted == true' \
          "''${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.claude.json" >/dev/null 2>&1; then
          set -- ${lib.concatMapStringsSep " " (dir:
        "--add-dir "
        + (
          if lib.hasPrefix "~/" dir
          then ''"$HOME"/${lib.escapeShellArg (lib.removePrefix "~/" dir)}''
          else lib.escapeShellArg dir
        ))
      dirs} "$@"
        fi
      fi
    ''}";
}
