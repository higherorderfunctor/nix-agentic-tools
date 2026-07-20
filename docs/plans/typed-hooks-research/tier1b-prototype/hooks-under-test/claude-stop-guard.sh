#!/usr/bin/env bash
# PROTOTYPE hook-under-test — Claude Stop, block + loop-guard path.
# Contract source: primary-source-hardening.md §4 (Stop decision control, docs L2216) — the same
# stop_hook_active loop-guard the repo's lib/validate-at-stop.sh implements (8-consecutive cap).
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

input="$(cat)"
stop_hook_active="$(jq -r '.stop_hook_active // false' <<<"$input")"
last_msg="$(jq -r '.last_assistant_message // ""' <<<"$input")"

# Loop guard: if Claude is ALREADY continuing due to a prior Stop block, never block again.
if [ "$stop_hook_active" = "true" ]; then
  # Advisory-only (systemMessage), no decision => the turn is allowed to end.
  jq -nc '{systemMessage: "stop-guard: loop guard active, not re-blocking"}'
  exit 0
fi

# Demo condition: block if the model claimed done without saying "tests pass".
if [[ -n $last_msg && $last_msg != *"tests pass"* && $last_msg == *"done"* ]]; then
  jq -nc '{decision: "block", reason: "Run the test suite before finishing."}'
  exit 0
fi

exit 0 # allow stop
