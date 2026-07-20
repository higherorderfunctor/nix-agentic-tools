#!/usr/bin/env bash
# PROTOTYPE hook-under-test — Claude PreToolUse, JSON decision-control path.
# Represents what the typed `ai.claude.hooks.PreToolUse` factory would EMIT via mkHookScript.
# Contract source: primary-source-hardening.md §4 (docs L1508 PreToolUse decision control).
#
# NOTE: a real factory-emitted hook bakes ABSOLUTE ${pkgs.jq}/bin/jq store paths (repo
# nix-standards: the hook env replaces PATH). Bare `jq` is used here only so the draft reads
# clean; the Tier-1b harness/derivation supplies jq on PATH via nativeBuildInputs.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

input="$(cat)"
tool_name="$(jq -r '.tool_name // ""' <<<"$input")"
command="$(jq -r '.tool_input.command // ""' <<<"$input")"

[ "$tool_name" = "Bash" ] || exit 0 # matcher is Bash; belt-and-suspenders in-script check

if [[ $command == *"rm -rf"* ]]; then
  # Block via hookSpecificOutput.permissionDecision:"deny" — NOT a top-level decision:"block".
  jq -nc '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "rm -rf is blocked by policy"
    }
  }'
  exit 0
fi

exit 0 # no decision => normal permission flow (allow)
