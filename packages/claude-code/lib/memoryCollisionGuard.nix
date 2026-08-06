# writeShellApplication wrapper for the agent-memory collision guard.
# See ./memory-collision-guard.sh for what it does and which of the two candidate
# instrumentations was chosen (deny-once) over the other (allow + additionalContext).
#
# Unlike delegationClamp.nix, the payload CANNOT be serialized at eval time: the
# denial reason embeds a directory listing that only exists at hook-run time. So jq
# is on the output path here, used as `jq -n --arg` — the text is passed as an
# ARGUMENT and jq does the escaping. Never string-concatenate JSON in the script;
# a memory `description:` line is arbitrary text and will contain quotes.
#
# runtimeInputs give absolute-PATH access under a stripped PATH (nix-standards):
# coreutils (realpath/date/sha256sum/basename/dirname/cut/sort/head/mkdir/touch),
# findutils (neighbour listing, marker prune), gnused (frontmatter extraction),
# jq (stdin parse + output serialization).
{
  lib,
  pkgs,
  # Minutes within which a neighbouring memory file's mtime counts as a live
  # concurrent session rather than as history.
  windowMinutes,
  # How many recently-modified neighbours to show.
  listCount,
  # Extra absolute directories to guard, beyond `<claude config>/projects/*/memory/`.
  extraDirectories,
}: let
  shellStrict = import ../../../config/shell-strict.nix;
in
  pkgs.writeShellApplication {
    name = "claude-memory-collision-guard";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnused
      pkgs.jq
    ];
    extraShellCheckFlags = shellStrict.shellcheckFlags;
    inherit (shellStrict) bashOptions;
    # shoptHeader must lead `text`: memory-collision-guard.sh re-asserts the full
    # header, but only from its own `set -euETo pipefail` line, which would leave
    # the injected assignments below running without inherit_errexit.
    #
    # MEMORY_GUARD_ROOT is deliberately NOT exported. Leaving it unset lets the
    # script derive the root from CLAUDE_CONFIG_DIR at run time, which is what keeps
    # the guard correct under config isolation; baking it would pin one home.
    text = ''
      ${shellStrict.shoptHeader}
      MEMORY_GUARD_WINDOW_MINUTES=${lib.escapeShellArg (toString windowMinutes)}
      MEMORY_GUARD_LIST_COUNT=${lib.escapeShellArg (toString listCount)}
      MEMORY_GUARD_EXTRA_DIRS=${lib.escapeShellArg (lib.concatStringsSep "\n" extraDirectories)}
      export MEMORY_GUARD_WINDOW_MINUTES MEMORY_GUARD_LIST_COUNT MEMORY_GUARD_EXTRA_DIRS
      ${builtins.readFile ./memory-collision-guard.sh}
    '';
  }
