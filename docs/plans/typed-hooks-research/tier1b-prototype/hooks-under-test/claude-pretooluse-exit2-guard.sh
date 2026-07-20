#!/usr/bin/env bash
# PROTOTYPE hook-under-test — Claude PreToolUse, EXIT-CODE-2 blocking path.
# Mirrors the anthropics reference impl (examples/hooks/bash_command_validator_example.py,
# ref 015170d3): exit 2 blocks the tool call and shows stderr to Claude; exit 1 does NOT block.
# Contract source: primary-source-hardening.md §3 + §7.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

input="$(cat)"
tool_name="$(jq -r '.tool_name // ""' <<<"$input")"
command="$(jq -r '.tool_input.command // ""' <<<"$input")"

[ "$tool_name" = "Bash" ] || exit 0
[ -n "$command" ] || exit 0

if [[ $command =~ ^grep\  ]]; then
  echo "Use 'rg' (ripgrep) instead of 'grep'" >&2
  exit 2 # exit 2 => block + stderr to Claude
fi

exit 0
