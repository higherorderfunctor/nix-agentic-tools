# Hermetic branch-test for packages/claude-code/lib/delegation-clamp.sh — the
# heron_brook mitigation hook. Exercises the once-per-session cadence, the
# PreCompact re-arm, and the degradation paths, against a stub payload.
#
# The cadence is the whole point of the script, so it is what this pins down: an
# `inject` that fired twice would silently restore per-turn cumulative context growth,
# and an `inject` that never fired would silently disable the mitigation. Both look
# identical from the outside — hence the test.
{pkgs, ...}:
pkgs.runCommandLocal "claude-delegation-clamp-check" {
  nativeBuildInputs = [pkgs.coreutils pkgs.findutils pkgs.jq pkgs.shellcheck];
  src = ../packages/claude-code/lib/delegation-clamp.sh;
} ''
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :

  outdir="$out"
  cp "$src" clamp.sh
  chmod +x clamp.sh
  shellcheck -x clamp.sh   # lint gate (matches the -x pre-commit standard)

  export XDG_RUNTIME_DIR="$PWD/run"
  mkdir -p "$XDG_RUNTIME_DIR"
  # Stub payload in its own file, mirroring how delegationClamp.nix bakes the real
  # one — the script reads a PATH, never an inlined JSON string.
  printf '%s' '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"STANDING REQUEST"}}' > payload.json
  export DELEGATION_CLAMP_PAYLOAD_FILE="$PWD/payload.json"

  pass=0; fail=0
  # run <mode> <stdin> -> stdout captured in $got, exit status in $rc
  run() {
    set +e
    got="$(printf '%s' "$2" | bash clamp.sh "$1" 2>/dev/null)"
    rc=$?
    set -e
  }
  ok()  { pass=$((pass+1)); echo "ok   - $1"; }
  bad() { fail=$((fail+1)); echo "FAIL - $1" >&2; }
  expect_exit0() { [ "$rc" -eq 0 ] || bad "$1: expected exit 0, got $rc"; }

  ENV1='{"session_id":"sess-one","cwd":"/w"}'
  ENV2='{"session_id":"sess-two","cwd":"/w"}'

  # 1. First inject emits the payload, and it is valid JSON naming UserPromptSubmit.
  run inject "$ENV1"; expect_exit0 "first inject"
  if printf '%s' "$got" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' >/dev/null 2>&1
  then ok "first inject emits valid UserPromptSubmit JSON"
  else bad "first inject did not emit valid UserPromptSubmit JSON (got: $got)"
  fi

  # 1b. The emitted context is the configured text, not a paraphrase or a truncation.
  if [ "$(printf '%s' "$got" | jq -r '.hookSpecificOutput.additionalContext')" = "STANDING REQUEST" ]
  then ok "additionalContext is the configured text verbatim"
  else bad "additionalContext did not round-trip"
  fi

  # 2. Second inject in the SAME session is silent — this is the cadence guarantee.
  run inject "$ENV1"; expect_exit0 "second inject"
  if [ -z "$got" ]; then ok "second inject in same session is silent"
  else bad "second inject re-emitted (cadence broken; cost would be cumulative)"; fi

  # 3. clear (PreCompact) then inject re-emits — the compaction re-arm.
  run clear "$ENV1"; expect_exit0 "clear"
  run inject "$ENV1"; expect_exit0 "inject after clear"
  if [ -n "$got" ]; then ok "inject re-emits after clear (PreCompact re-arm)"
  else bad "inject did not re-emit after clear; compaction would silently disable it"; fi

  # 4. A DIFFERENT session is independent of the first.
  run inject "$ENV2"; expect_exit0 "other session inject"
  if [ -n "$got" ]; then ok "a second session injects independently"
  else bad "second session was suppressed by the first session's marker"; fi

  # 5. Malformed stdin must not kill the hook (a non-zero UserPromptSubmit hook
  #    surfaces to the user as an error), and it must land on the SAME fixed fallback
  #    key that an absent session_id uses. A fallback that varied per call would inject
  #    on every turn, silently restoring exactly the cumulative cost this design avoids.
  run clear '{}'   # reset the fallback key before asserting on it
  run inject 'not json{'; expect_exit0 "malformed stdin"
  malformed_out="$got"
  run inject '{}'; expect_exit0 "absent session_id after malformed"
  if [ -n "$malformed_out" ] && [ -z "$got" ]
  then ok "malformed stdin and absent session_id share one fixed fallback key"
  else bad "fallback key is not fixed across degraded inputs"
  fi

  # 6. And that fallback key still obeys the once-per-session cadence.
  run clear '{}'
  run inject '{}'; expect_exit0 "fallback key (first)"
  first_fallback="$got"
  run inject '{}'; expect_exit0 "fallback key (second)"
  if [ -n "$first_fallback" ] && [ -z "$got" ]
  then ok "fallback key injects exactly once"
  else bad "fallback key did not inject exactly once"
  fi

  # 7. An unknown mode is inert rather than fatal.
  run bogus "$ENV1"; expect_exit0 "unknown mode"
  ok "unknown mode exits 0"

  # 8. A session_id containing path separators cannot escape the marker directory.
  run inject '{"session_id":"../../escape"}'; expect_exit0 "traversal session_id"
  if [ -z "$(find "$XDG_RUNTIME_DIR/claude-delegation-clamp" -name '*escape*' -prune -o -type d -print 2>/dev/null | grep -v "^$XDG_RUNTIME_DIR/claude-delegation-clamp$" || :)" ]
  then ok "path-separator session_id is sanitized into a flat marker name"
  else bad "session_id escaped the marker directory"
  fi

  echo "claude-delegation-clamp: $pass passed, $fail failed"
  [ "$fail" -eq 0 ] || exit 1
  touch "$outdir"
''
