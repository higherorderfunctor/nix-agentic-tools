#!/usr/bin/env bash
# PROTOTYPE hook-under-test — Claude SessionStart, context-injection path.
# Contract source: primary-source-hardening.md §4 (SessionStart decision control, docs L950).
# SessionStart cannot block; it injects additionalContext (+ initialUserMessage / reloadSkills / …).
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

input="$(cat)"
source="$(jq -r '.source // "startup"' <<<"$input")"

# Emit context only on a fresh startup; on resume/clear/compact stay silent to demo matcher-awareness.
if [ "$source" = "startup" ]; then
  jq -nc '{
    hookSpecificOutput: {
      hookEventName: "SessionStart",
      additionalContext: "Repo uses bun test. Active branch context injected by hook.",
      reloadSkills: false
    }
  }'
fi

exit 0
