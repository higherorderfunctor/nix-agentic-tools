# TRIPWIRE 2 for the heron_brook delegation-clamp mitigation: fail as soon as the
# pinned Claude Code version moves, so a new client build cannot land unattended
# while carrying a mitigation nobody re-verified against it.
#
# Why this lives in `nix flake check` rather than in the update workflow: the
# requirement is that the BOT'S `update/*` PR for claude-code goes red. Those PRs arm
# GitHub-native auto-merge and land themselves once the five required checks pass, so
# a gate that runs only in the update job would not stop one. `nix flake check` is the
# repo's stated validation entrypoint, it is covered by the required `test` status
# check, and it has no path filter to fall through — the same reasoning
# checks/instructions-drift.nix records for itself.
#
# Version comparison ONLY, deliberately. Grepping the built binary for the clamp
# strings would be a direct measurement rather than a proxy, but it would drag a
# ~275 MB claude-code build into every `nix flake check`. The version move is a
# sufficient trigger; the both-polarity grep belongs in the human re-verification
# procedure, which private/heron-brook-delegation-clamp.md § 5 specifies with its
# mandatory positive control.
#
# Eval-pure: both inputs are committed JSON read with readFile (no IFD).
{pkgs, ...}: let
  tripwire = builtins.fromJSON (builtins.readFile ../config/heron-brook-tripwire.json);
  sources = builtins.fromJSON (builtins.readFile ../overlays/claude-code-sources.json);
  inherit (tripwire) issue verifiedClaudeVersion;
  pinned = sources.version;
in {
  claude-heron-brook =
    pkgs.runCommandLocal "claude-heron-brook-check" {}
    (
      if pinned == verifiedClaudeVersion
      then "touch $out"
      else ''
        echo "FAIL: claude-code moved from ${verifiedClaudeVersion} to ${pinned}." >&2
        echo "" >&2
        echo "The heron_brook delegation clamp that ai.claude.delegationClamp mitigates" >&2
        echo "is undocumented client behavior. A new build may have removed it, changed" >&2
        echo "its wording, or changed its gate — in which case the mitigation is either" >&2
        echo "unnecessary overhead or no longer effective. Neither is visible in a diff." >&2
        echo "" >&2
        echo "Re-verify before landing this version. The procedure (with its REQUIRED" >&2
        echo "positive control — a clean negative from an unverified grep on a 275 MB" >&2
        echo "binary proves nothing) is in:" >&2
        echo "  private/heron-brook-delegation-clamp.md § 5" >&2
        echo "  packages/claude-code/docs/heron-brook-clamp.md" >&2
        echo "  ${issue}" >&2
        echo "" >&2
        echo "Then EITHER set verifiedClaudeVersion to ${pinned} in" >&2
        echo "config/heron-brook-tripwire.json, OR — if upstream fixed it — delete the" >&2
        echo "mitigation and both tripwires. An expired justification is a finding, not" >&2
        echo "a formality to bump past." >&2
        exit 1
      ''
    );
}
