#!/usr/bin/env bash
#
# Self-test for the seed-and-assert chain, with NO Kiro launch.
#
# The live runs are operator-driven, but the part that most needs testing is not
# the launch — it is the DECISION TREE that interprets the result. A seeded
# session that was never read produces no error, so assert-seed-took.sh is the
# only thing standing between "the enable path does not work" and "I put the file
# in the wrong directory". A decision tree nobody has exercised is not a decision
# tree.
#
# So every branch is driven here against a FABRICATED log. Fabrication is honest
# for this purpose: the assertions are string and filesystem predicates over log
# content, and what is being tested is the predicate, not the engine. The engine
# facts those strings encode are established in the corpus records; the live runs
# confirm the strings appear.
#
# Writes only under its own scratch root. Launches nothing.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

root="${TMPDIR:-/tmp}/kiro-mode-f-self-test.$$"
trap 'rm -rf "$root" "${root%/}.logs-kept" 2>/dev/null || :' EXIT

pass_n=0
fail_n=0

check() {
  local label="$1" want="$2"
  shift 2
  local out rc
  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set -e
  if [ "$want" = "pass" ] && [ "$rc" -eq 0 ]; then
    printf 'ok    %s\n' "$label"
    pass_n=$((pass_n + 1))
    return 0
  fi
  if [ "$want" = "fail" ] && [ "$rc" -ne 0 ]; then
    printf 'ok    %s (refused as expected)\n' "$label"
    pass_n=$((pass_n + 1))
    return 0
  fi
  printf 'FAIL  %s (wanted %s, got rc=%d)\n' "$label" "$want" "$rc" >&2
  printf '      %s\n' "$out" >&2
  fail_n=$((fail_n + 1))
  return 0
}

# Fabricate an engine log that says the right things. Every string here is a
# substring the real engine emits; assert-seed-took.sh matches on substrings, so
# this exercises the same code path a real log would.
write_log() {
  local home="$1" sid="$2" root_path="$3" extra="${4:-}" loads="${5:-2}"
  local dir="$home/.kiro/logs/20260730T000000"
  mkdir -p "$dir"
  {
    printf '{"level":"info","msg":"Initializing persistence at %s"}\n' "$root_path"
    local i=0
    while [ "$i" -lt "$loads" ]; do
      printf '{"level":"info","msg":"[SessionPersistence] Loaded session %s"}\n' "$sid"
      i=$((i + 1))
    done
    # An `if` rather than `[ -n "$extra" ] && printf ...` on purpose: that form
    # would be the LAST command in this group, so an empty $extra makes the
    # group exit 1 and inherit_errexit kills the caller. Strict mode caught it
    # here; it is worth not reintroducing.
    if [ -n "$extra" ]; then
      printf '%s\n' "$extra"
    fi
  } >"$dir/kiro.log"
}

setup() {
  rm -rf "$root"
  export KIRO_FIXTURE_SCRATCH="$root"
  local out
  out="$("$here/scratch-up.sh")"
  eval "$out"
  SEED_OUT="$("$here/seed-session.sh")"
  SID="$(printf '%s' "$SEED_OUT" | sed -n 's/^session_id=//p')"
  SESSION_DIR="$(printf '%s' "$SEED_OUT" | sed -n 's/^session_dir=//p')"
}

# --- the happy path --------------------------------------------------------
setup
write_log "$KIRO_FIXTURE_HOME" "$SID" "$KIRO_FIXTURE_HOME/.kiro/sessions"
check "a well-formed run is accepted" pass "$here/assert-seed-took.sh" "$SID"

# --- branch 1: no log at all ----------------------------------------------
setup
check "no engine log is refused" fail "$here/assert-seed-took.sh" "$SID"

# --- branch 1b: the log names the WRONG session root ----------------------
# This is the two-root failure: the redirect did not reach the engine, so it
# initialized persistence against the real home instead of the scratch one.
setup
write_log "$KIRO_FIXTURE_HOME" "$SID" "/some/other/home/.kiro/sessions"
check "a wrong session root is refused" fail "$here/assert-seed-took.sh" "$SID"

# --- branch 2: the create-uncreated marker -------------------------------
# The silent failure this whole script exists for: the seed was not found, a
# fresh session was created, and workflows are off.
setup
write_log "$KIRO_FIXTURE_HOME" "$SID" "$KIRO_FIXTURE_HOME/.kiro/sessions" \
  '{"level":"info","msg":"session.load.create_uncreated"}'
check "the create_uncreated marker is refused" fail "$here/assert-seed-took.sh" "$SID"

# --- branch 3: zero load lines -------------------------------------------
setup
write_log "$KIRO_FIXTURE_HOME" "$SID" "$KIRO_FIXTURE_HOME/.kiro/sessions" '' 0
check "zero 'Loaded session' lines is refused" fail "$here/assert-seed-took.sh" "$SID"

# --- branch 4: a rival session directory ---------------------------------
# The on-disk footprint of create-uncreated, caught independently of the log
# string in case that string is ever renamed.
setup
write_log "$KIRO_FIXTURE_HOME" "$SID" "$KIRO_FIXTURE_HOME/.kiro/sessions"
mkdir -p "$(dirname "$SESSION_DIR")/sess_rival-0000-0000-0000-000000000000"
check "a rival session directory is refused" fail "$here/assert-seed-took.sh" "$SID"

# --- branch 5: the flag did not survive ----------------------------------
setup
write_log "$KIRO_FIXTURE_HOME" "$SID" "$KIRO_FIXTURE_HOME/.kiro/sessions"
tmp="$(mktemp "${TMPDIR:-/tmp}/kiro-seed-self_test.XXXXXX")"
jq '.workflowsEnabled = false' "$SESSION_DIR/session.json" >"$tmp"
mv "$tmp" "$SESSION_DIR/session.json"
check "workflowsEnabled=false after the run is refused" fail "$here/assert-seed-took.sh" "$SID"

# --- seed-session's own refusals -----------------------------------------
setup
check "an id failing the engine charset is refused" fail \
  "$here/seed-session.sh" 'bad id with spaces'

# --- teardown guards -----------------------------------------------------
# The guard that matters: a scratch root pointing at the real home must be
# refused, because teardown is a recursive delete.
setup
check "teardown refuses the real home as the scratch root" fail \
  env KIRO_FIXTURE_SCRATCH="$HOME" "$here/scratch-down.sh"
check "teardown refuses / as the scratch root" fail \
  env KIRO_FIXTURE_SCRATCH=/ "$here/scratch-down.sh"

# --- teardown happy path -------------------------------------------------
setup
check "teardown removes its own scratch root" pass "$here/scratch-down.sh"
if [ -d "$root" ]; then
  echo 'FAIL  teardown reported success but the scratch root still exists' >&2
  fail_n=$((fail_n + 1))
else
  printf 'ok    scratch root is gone after teardown\n'
  pass_n=$((pass_n + 1))
fi

# --- report ---------------------------------------------------------------
printf '\npassed: %d\nfailed: %d\n' "$pass_n" "$fail_n"
if [ "$pass_n" -eq 0 ]; then
  echo 'FAIL: no checks ran' >&2
  exit 1
fi
if [ "$fail_n" -ne 0 ]; then
  exit 1
fi
echo 'PASS'
