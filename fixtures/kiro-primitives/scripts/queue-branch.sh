#!/usr/bin/env bash
#
# One drain branch: re-dispatch a single-item worker until the queue is drained.
#
# This is the shell stand-in for one `repeat` branch of the native workflow's
# `parallel` node, and it is written to have the same shape on purpose:
#
#   - the body is ONE worker invocation working ONE item, so every iteration is
#     a fresh short-lived worker;
#   - the stop condition is the `drained` flag and is evaluated AFTER the body,
#     never before, so a branch always burns at least one iteration even against
#     an already-drained queue;
#   - `--max-iterations` is the backstop and aborting is what it does on
#     exhaustion (the workflow engine's `onMaxIterations: "pause"` is a trap --
#     resuming grants no further iterations and a paused run cannot be retried).
#
# The worker never polls: an empty claim exits 3 and the worker RETURNS. What
# loops here is the ORCHESTRATOR's re-dispatch, and `--turn-ms` stands in for
# the agent turn a real drain would spend on it.
#
# Termination is `drained`, NOT the dry counter. `dry_threshold` cannot safely
# terminate a branch on its own once late-proposers exist: a branch can go empty
# while another worker still holds the item whose completion will push a child,
# and if every branch retired on that signal the child would be dropped.
# `drained` already requires nothing to be in flight, so it is the only safe
# terminator; the dry count below is reported, not obeyed.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

root=""
owner=""
max_iterations=400
turn_ms=""
strategy="exclusive"

usage() {
  cat <<'EOF'
usage: queue-branch.sh --root DIR --owner NAME [options]

  --root DIR           run root created by queue_init.py
  --owner NAME         claimant name for this branch
  --max-iterations N   abort after N re-dispatches (default 400)
  --turn-ms N          delay between re-dispatches (default: config unit_ms)
  --strategy S         exclusive | read-then-write (TEST-ONLY control)

exit: 0 drained, 4 max-iterations abort, 5 invariant violation, 1 error
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
  --root)
    root="$2"
    shift 2
    ;;
  --owner)
    owner="$2"
    shift 2
    ;;
  --max-iterations)
    max_iterations="$2"
    shift 2
    ;;
  --turn-ms)
    turn_ms="$2"
    shift 2
    ;;
  --strategy)
    strategy="$2"
    shift 2
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "queue-branch: unknown argument: $1" >&2
    usage >&2
    exit 1
    ;;
  esac
done

if [ -z "$root" ] || [ -z "$owner" ]; then
  echo "queue-branch: --root and --owner are required" >&2
  exit 1
fi

if [ -z "$turn_ms" ]; then
  turn_ms="$(jq -r '.unit_ms' "$root/config.json")"
fi
dry_threshold="$(jq -r '.dry_threshold' "$root/config.json")"

# Fractional sleep without spawning a second interpreter per iteration. printf
# builds the seconds value because `sleep 0.$(...)` breaks the moment the delay
# reaches a whole second.
sleep_ms() {
  local ms="$1"
  [ "$ms" -gt 0 ] || return 0
  sleep "$(printf '%d.%03d' "$((ms / 1000))" "$((ms % 1000))")"
}

iterations=0
worked=0
empty=0
failed=0
consecutive_empty=0
max_consecutive_empty=0
verdict="drained"
status=0

while :; do
  iterations=$((iterations + 1))
  if [ "$iterations" -gt "$max_iterations" ]; then
    verdict="max_iterations_abort"
    status=4
    break
  fi

  rc=0
  "$here/queue_worker.py" \
    --root "$root" \
    --owner "$owner" \
    --strategy "$strategy" \
    >/dev/null || rc=$?

  case "$rc" in
  0)
    worked=$((worked + 1))
    consecutive_empty=0
    ;;
  3)
    empty=$((empty + 1))
    consecutive_empty=$((consecutive_empty + 1))
    if [ "$consecutive_empty" -gt "$max_consecutive_empty" ]; then
      max_consecutive_empty="$consecutive_empty"
    fi
    ;;
  4)
    failed=$((failed + 1))
    consecutive_empty=0
    ;;
  5)
    verdict="invariant_violation"
    status=5
    break
    ;;
  *)
    verdict="worker_error_rc_${rc}"
    status=1
    break
    ;;
  esac

  # Post-body stop check, exactly where the `repeat` node evaluates it.
  drained="$("$here/queue_status.py" --root "$root" --field drained)"
  if [ "$drained" = "true" ]; then
    break
  fi
  sleep_ms "$turn_ms"
done

# `dry_threshold` is REPORTED, never acted on -- see the header. Surfacing it is
# what keeps the config key honest: a knob nothing reads is a knob that has
# silently stopped meaning anything.
dry_exceeded=false
if [ "$max_consecutive_empty" -ge "$dry_threshold" ]; then
  dry_exceeded=true
fi

jq -n \
  --arg owner "$owner" \
  --arg verdict "$verdict" \
  --argjson dry_threshold "$dry_threshold" \
  --argjson dry_threshold_exceeded "$dry_exceeded" \
  --argjson empty "$empty" \
  --argjson failed "$failed" \
  --argjson iterations "$iterations" \
  --argjson max_consecutive_empty "$max_consecutive_empty" \
  --argjson worked "$worked" \
  '{$dry_threshold, $dry_threshold_exceeded, $empty, $failed, $iterations,
    $max_consecutive_empty, $owner, $verdict, $worked}'

exit "$status"
