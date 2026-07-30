# shellcheck shell=bash
#
# Shared helpers for the hook probes. Source this; do not execute it.
#
# THE STATE DIRECTORY IS DELIBERATELY OUTSIDE THE WORKSPACE. Writing the probe
# log into the workspace would itself fire the PostFileCreate / PostFileSave
# triggers that the quiet probes exist to measure, so the probe would perturb
# exactly the thing it observes — and on a save-per-record basis, it would do so
# once per record, unboundedly. Keep KIRO_PROBE_STATE outside every workspace
# root you open, and never point it inside ~/.kiro.
#
# READING STDIN: every probe reads to EOF, never a single line. The engine
# terminates the child's stdin after writing the payload, so a read-to-EOF
# terminates; a line-oriented read would truncate any payload the engine ever
# pretty-prints and would silently succeed today.

if [ -z "${BASH_VERSION:-}" ]; then
  echo "probe-lib.sh requires bash" >&2
  return 1
fi

# Where probe state lives. One directory holds the log and the one-shot
# sentinels, so an operator re-arms every probe by removing one path.
probe_state_dir() {
  printf '%s\n' "${KIRO_PROBE_STATE:-${TMPDIR:-/tmp}/kiro-probe}"
}

probe_log_path() {
  printf '%s/probe.log\n' "$(probe_state_dir)"
}

# Read stdin to EOF and print it. Named so that a future edit to a probe cannot
# quietly become a `read -r line`.
probe_slurp() {
  cat
}

# Append one record. Two lines per record: a header naming the marker, and the
# payload verbatim. Deliberately dependency-free — no jq at hook run time, since
# a hook inherits the agent's PATH and a missing tool would present as a probe
# that "did not fire".
probe_record() {
  local marker="$1" payload="$2" dir
  dir="$(probe_state_dir)"
  mkdir -p "$dir"
  {
    printf '=== %s %s pid=%s ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$marker" "$$"
    printf '%s\n' "$payload"
  } >>"$dir/probe.log"
}

# Claim a one-shot: succeeds exactly once per state directory.
#
# `mkdir` is the atomic primitive here — it fails if the directory exists, with
# no test-then-act window. A `[ -e ] && touch` pair would race two concurrent
# turns and let a Stop probe inject twice, which for an exit-1 Stop hook means
# two graph restarts instead of one. stderr is discarded because the second call
# is the EXPECTED path, not an error, and on a SessionStart or UserPromptSubmit
# probe an empty stdout promotes stderr into the conversation.
probe_claim_once() {
  local claim="$1" dir
  dir="$(probe_state_dir)"
  mkdir -p "$dir"
  mkdir "$dir/claim-$claim" 2>/dev/null
}
