#!/usr/bin/env bash
#
# Behavioral self-test for the hook probe scripts.
#
# The linter checks the DOCUMENTS. This checks the SCRIPTS, by feeding each one a
# synthetic hook payload on stdin exactly as the engine would and asserting on
# its three observable outputs: stdout, stderr and exit code. Those three are the
# whole contract — what the engine does with a hook is a pure function of them
# plus the trigger.
#
# The load-bearing assertion is the multi-line payload. A probe that read one
# line instead of to EOF would still pass every other check here, because a
# compact single-line payload is what the engine sends today. Feeding a
# pretty-printed payload is the only way to tell a read-to-EOF from a read-a-line
# BEFORE the engine's formatting changes under us.
#
# STARTS NOTHING. No Kiro process is launched; the scripts are invoked directly.
# Writes only inside its own mktemp directory.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin_dir="$(cd "$here/../hooks/bin" && pwd)"

work="$(mktemp -d "${TMPDIR:-/tmp}/kiro-hook-probes-self_test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

export KIRO_PROBE_STATE="$work/state"

passed=0
failed=0

# A pretty-printed payload, on purpose. Its field set is the SessionStart arm of
# the engine's input builder: the three common fields and nothing else.
payload_file="$work/payload.json"
cat >"$payload_file" <<'PAYLOAD'
{
  "session_id": "self-test-session",
  "hook_event_name": "SessionStart",
  "cwd": "/nowhere"
}
PAYLOAD

log_path() {
  printf '%s/probe.log\n' "$KIRO_PROBE_STATE"
}

ok() {
  printf 'ok   %s\n' "$1"
  passed=$((passed + 1))
}

bad() {
  printf 'not ok - %s\n' "$1"
  failed=$((failed + 1))
}

check() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    ok "$label"
  else
    bad "${label} (expected '${expected}', got '${actual}')"
  fi
}

# Run one probe against the payload, capturing all three observables.
run_probe() {
  local script="$1" marker="$2" rc=0
  probe_out="$work/out"
  probe_err="$work/err"
  "$bin_dir/$script" "$marker" <"$payload_file" >"$probe_out" 2>"$probe_err" || rc=$?
  probe_rc="$rc"
}

echo '--- probe-inject.sh (SessionStart / UserPromptSubmit shape) -----------'
rm -rf "$KIRO_PROBE_STATE"
run_probe probe-inject.sh inject-case
check 'inject exits 0' 0 "$probe_rc"
check 'inject writes NOTHING to stderr' 0 "$(wc -c <"$probe_err")"
if grep -q '^PROBE inject-case fired' "$probe_out"; then
  ok 'inject writes a marker line to stdout (the injected text)'
else
  bad "inject stdout is not the marker line: $(cat "$probe_out")"
fi

echo
echo '--- the payload is read to EOF, not one line -------------------------'
# Every line of the pretty-printed payload must appear in the log. This is the
# control that fails loudly if a probe ever regresses to `read -r line`.
missing=0
while IFS= read -r line; do
  if ! grep -Fqx "$line" "$(log_path)"; then
    missing=$((missing + 1))
    printf '        missing payload line: %s\n' "$line"
  fi
done <"$payload_file"
check 'every payload line reached the log' 0 "$missing"
check 'exactly one record was written' 1 "$(grep -c '^=== ' "$(log_path)")"

echo
echo '--- probe-quiet.sh (PostToolUse / PostFile* shape) --------------------'
rm -rf "$KIRO_PROBE_STATE"
run_probe probe-quiet.sh quiet-case
check 'quiet exits 0' 0 "$probe_rc"
check 'quiet writes NOTHING to stdout' 0 "$(wc -c <"$probe_out")"
check 'quiet writes NOTHING to stderr' 0 "$(wc -c <"$probe_err")"
check 'quiet still records' 1 "$(grep -c '^=== ' "$(log_path)")"

echo
echo '--- probe-stop-loop.sh (the loop primitive, armed once) ---------------'
rm -rf "$KIRO_PROBE_STATE"
run_probe probe-stop-loop.sh stop-case
# Exit 1 is the whole point: it is the only code that continues the graph.
check 'first call exits 1' 1 "$probe_rc"
if grep -q 'PROBE stop-case injected' "$probe_err"; then
  ok 'first call puts its reason on STDERR (stderr is read first)'
else
  bad "first call stderr is not the reason: $(cat "$probe_err")"
fi
if grep -q "claim-stop-case" "$probe_err"; then
  ok 'the injected text names the sentinel path, so re-arming is self-documenting'
else
  bad 'the injected text does not name the sentinel path'
fi
check 'first call writes nothing to stdout' 0 "$(wc -c <"$probe_out")"
check 'the sentinel exists' 1 "$([ -d "$KIRO_PROBE_STATE/claim-stop-case" ] && echo 1 || echo 0)"

run_probe probe-stop-loop.sh stop-case
# Exit 0 with empty stdout routes to the stop-decision parser, which finds no
# decision and lets the turn end. Anything else here is an unbounded loop.
check 'second call exits 0' 0 "$probe_rc"
check 'second call writes nothing to stdout' 0 "$(wc -c <"$probe_out")"
check 'second call writes nothing to stderr' 0 "$(wc -c <"$probe_err")"
check 'both calls were recorded' 2 "$(grep -c '^=== ' "$(log_path)")"

rm -rf "$KIRO_PROBE_STATE/claim-stop-case"
run_probe probe-stop-loop.sh stop-case
check 'removing the sentinel re-arms the probe' 1 "$probe_rc"

echo
echo '--- the state directory is the only thing written ---------------------'
# The probes must not touch the tree they are run from. `find -newer` against a
# marker created before the runs is the check that a stray write would fail.
touch "$work/.marker"
run_probe probe-quiet.sh marker-case
stray="$(find "$bin_dir" -newer "$work/.marker" -type f | wc -l)"
check 'no file under hooks/bin was modified' 0 "$stray"

echo
echo '--- negative control: a line-oriented read must FAIL that check --------'
# The payload assertion above is only worth running if it can fail. Rebuild the
# probes with exactly the mistake this corpus warns about - a single-line read
# instead of a read to EOF - and confirm the check catches it. A later bash
# definition wins, so appending an override to the copied library is enough and
# needs no surgery on the original.
mutated="$work/mutated-bin"
cp -r "$bin_dir" "$mutated"
cat >>"$mutated/probe-lib.sh" <<'OVERRIDE'
probe_slurp() {
  read -r one_line
  printf '%s\n' "$one_line"
}
OVERRIDE
rm -rf "$KIRO_PROBE_STATE"
"$mutated/probe-inject.sh" control-case <"$payload_file" >"$work/out" 2>"$work/err"
control_missing=0
while IFS= read -r line; do
  if ! grep -Fqx "$line" "$(log_path)"; then
    control_missing=$((control_missing + 1))
  fi
done <"$payload_file"
if [ "$control_missing" -gt 0 ]; then
  ok "the check rejects a line-oriented read (${control_missing} payload line(s) lost)"
else
  bad 'a line-oriented read passed the payload check - the check proves nothing'
fi

echo
printf 'assertions passed: %d\n' "$passed"
printf 'assertions failed: %d\n' "$failed"

# A denominator of zero is not a pass, and neither is a run that skipped a
# section. Bump this when an assertion is added; if it ever disagrees, the run
# stopped early or a branch was silently not taken.
expected=21
if [ "$((passed + failed))" -ne "$expected" ]; then
  printf 'FAIL: ran %d assertions, expected %d\n' "$((passed + failed))" "$expected" >&2
  exit 1
fi
if [ "$failed" -ne 0 ]; then
  printf 'FAIL: %d assertion(s) did not hold\n' "$failed" >&2
  exit 1
fi
echo 'PASS'
