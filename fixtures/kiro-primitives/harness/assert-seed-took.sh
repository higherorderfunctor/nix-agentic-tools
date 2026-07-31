#!/usr/bin/env bash
#
# Decide whether a seeded session was ACTUALLY loaded — and if not, which of the
# several silent failures happened.
#
# This script exists because the dangerous failure is not an error. Loading an
# unknown session id does NOT fail: the engine hydrates a fresh session with
# default feature flags (workflows off) and then persists it over the path. So a
# mis-bucketed or mis-named seed presents as "the workflow flag didn't work",
# which is indistinguishable from "the enable path doesn't work" unless
# something checks. Never infer success from the session merely opening.
#
# Usage: assert-seed-took.sh <session-id>
#   Reads KIRO_FIXTURE_HOME and KIRO_FIXTURE_WORKSPACE.
#   Exits non-zero on the first check that fails, naming the diagnosis.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"

: "${KIRO_FIXTURE_HOME:?run scratch-up.sh and eval its output first}"
: "${KIRO_FIXTURE_WORKSPACE:?run scratch-up.sh and eval its output first}"

session_id="${1:?usage: assert-seed-took.sh <session-id>}"

bucket="$(kiro_bucket "$KIRO_FIXTURE_WORKSPACE")"
bucket_dir="$KIRO_FIXTURE_HOME/.kiro/sessions/$bucket"
session_dir="$bucket_dir/$session_id"

fail() {
  printf 'FAIL  %s\n' "$1" >&2
  printf '      diagnosis: %s\n' "$2" >&2
  exit 1
}
pass() { printf 'ok    %s\n' "$1"; }

# --- 1. the HOME redirect actually took ------------------------------------
# Every engine start writes the resolved session root to its log. Reading it is
# the only trustworthy confirmation; inferring it from the environment is what
# the two-root confusion punishes.
log="$(kiro_newest_log "$KIRO_FIXTURE_HOME")" || fail \
  "no engine log under the scratch HOME" \
  "the engine never started with this HOME, or it wrote its log elsewhere - so the redirect did NOT take"

logged_root="$(kiro_logged_session_root "$log")"
expected_root="$KIRO_FIXTURE_HOME/.kiro/sessions"
if [ "$logged_root" != "$expected_root" ]; then
  fail "session root is '${logged_root}', expected '${expected_root}'" \
    "the HOME redirect did not reach the engine. If this names the real home, the launcher resolved os.homedir() from something other than the HOME we set"
fi
pass "HOME redirect took - engine initialized persistence at the scratch root"

# --- 2. the seed was found, not re-created --------------------------------
# The presence of this marker is definitive: it is logged exactly when a load
# targets an id that does not exist on disk.
if grep -qF 'session.load.create_uncreated' "$log"; then
  fail "'session.load.create_uncreated' is present in the log" \
    "the seed was NOT found, so a fresh session was created with workflows OFF. Almost always a bucket mismatch: the bucket comes from the request cwd, so re-check that the launch cwd is exactly the workspace whose hash names the bucket"
fi
pass "no create_uncreated marker - the load did not fall back to creating"

# --- 3. exactly two loads of the same metadata file ------------------------
# One session/load performs TWO reads of the same session.json: the persistence
# layer's (whose record feeds the workflow gate) and the message store's (whose
# record feeds replay). Both derive the bucket from the same client-supplied
# paths, so they cannot disagree. One or zero means the seed was not picked up.
loaded_count="$(grep -cF "Loaded session ${session_id}" "$log" || true)"
if [ "$loaded_count" -eq 0 ]; then
  fail "no 'Loaded session ${session_id}' line in the log" \
    "the engine never loaded this id. Check the id passed to --resume-id against the seeded id"
fi
if [ "$loaded_count" -ne 2 ]; then
  printf 'warn  expected 2 "Loaded session" lines, saw %d\n' "$loaded_count" >&2
  printf '      not fatal, but the two-read invariant changed - re-read the load path before trusting other assertions\n' >&2
else
  pass "two 'Loaded session' lines - persistence and message store both read the seed"
fi

# --- 4. no rival session was created in the bucket -------------------------
# The create-uncreated path leaves a NEW session directory behind. Counting is a
# second, independent witness to check 2, and it catches the case where the
# marker string itself has been renamed.
shopt -s nullglob
present=("$bucket_dir"/*/)
if [ "${#present[@]}" -eq 0 ]; then
  fail "the bucket ${bucket} contains no session directories at all" \
    "the seed is gone, or the bucket was computed differently here than when seeding"
fi
if [ "${#present[@]}" -ne 1 ]; then
  printf 'FAIL  bucket %s holds %d session directories, expected exactly 1\n' \
    "$bucket" "${#present[@]}" >&2
  printf '      diagnosis: a rival session was created alongside the seed, which is the on-disk footprint of the silent create-uncreated path\n' >&2
  printf '      present:\n' >&2
  printf '        %s\n' "${present[@]}" >&2
  exit 1
fi
pass "exactly one session directory in the bucket - nothing rival was created"

# --- 5. the flag survived the session's own writes -------------------------
# Every metadata write either spreads the parsed metadata or rebuilds it from the
# resolved in-memory flag, so no write path drops the key. If it is false here,
# the gate resolved false and persisted that — which means the seed was not the
# thing that was read.
if [ ! -f "$session_dir/session.json" ]; then
  fail "no session.json at ${session_dir}" \
    "the seeded session directory is gone"
fi
flag="$(jq -r '.workflowsEnabled // "absent"' "$session_dir/session.json")"
if [ "$flag" != "true" ]; then
  fail "workflowsEnabled is '${flag}' after the run" \
    "the gate resolved false and persisted it. The seed was present but not honored - re-check that the flag was at the TOP level of the file, since a nested key is silently stripped"
fi
pass "workflowsEnabled is still true after the run"

# --- 6. did KIRO_LOG_LEVEL reach the engine? ------------------------------
# Reported, not asserted. Whether the Rust launcher forwards its environment to
# the spawned engine is not established, and several useful signals are
# debug-only. One hit settles it; zero means fall back to info-level and
# transcript assertions.
if grep -q '"level":"debug"' "$log"; then
  pass "debug-level logging reached the engine - adapter/hook diagnostics available"
else
  printf 'note  no debug lines in the log: KIRO_LOG_LEVEL did not reach the engine\n'
  printf '      fall back to info-level lines and transcript events; adapter selection and\n'
  printf '      untrusted-workspace hook suppression will not be observable this run\n'
fi

printf '\nPASS  the seed was loaded and the workflow gate saw it\n'
printf 'log:  %s\n' "$log"
