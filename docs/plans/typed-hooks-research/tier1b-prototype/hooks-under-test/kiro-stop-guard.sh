#!/usr/bin/env bash
# PROTOTYPE hook-under-test — Kiro v3 Stop, JSON decision-block channel (command action).
# Contract source: assessment §5.3 + verdicts.json ([R] fix): Kiro Stop CAN block via
# stdout `{"decision":"block","reason":...}` (reason -> new user message), OR exit 2.
# Kiro stdin is METADATA-ONLY — CONFIRMED on 2.13.0 (Tier-2 probe 2026-07-20): Stop stdin is exactly
# {session_id, hook_event_name, cwd}, with NO assistant_response field at all (resolves §12 Q4). This
# guard therefore keys off a side-channel marker file rather than stdin content — exactly the constraint
# autoMemory hit.
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
