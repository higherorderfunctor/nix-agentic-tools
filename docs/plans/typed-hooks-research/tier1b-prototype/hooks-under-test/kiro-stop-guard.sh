#!/usr/bin/env bash
# PROTOTYPE hook-under-test — Kiro v3 Stop, JSON decision-block channel (command action).
# Contract source: assessment §5.3 + verdicts.json ([R] fix): Kiro Stop CAN block via
# stdout `{"decision":"block","reason":...}` (reason -> new user message), OR exit 2.
# Kiro stdin is METADATA-ONLY on 2.11/2.12 ({session_id, cwd, hook_event_name}); the documented
# `assistant_response` arrives empty (§12 Q4, pending 2.13 re-capture). This guard therefore keys
# off a side-channel marker file rather than stdin content — exactly the constraint autoMemory hit.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

input="$(cat)"
cwd="$(jq -r '.cwd // ""' <<<"$input")"

# Metadata-only contract: prove the hook can locate its own state from cwd (no prompt/response on stdin).
if [ -n "$cwd" ] && [ -f "$cwd/.needs-tests" ]; then
  jq -nc '{decision: "block", reason: "You have not run the tests yet."}'
  exit 0
fi

exit 0 # allow stop
