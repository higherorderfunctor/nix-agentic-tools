#!/usr/bin/env bash
#
# The loop primitive, armed exactly once.
#
# A Stop hook exiting 1 takes `stderr.trim() || stdout.trim()` as a reason,
# wraps it in <HOOK_INSTRUCTION> tags, appends it as a NEW HUMAN MESSAGE, and
# returns state with shouldRestartGraph — so the turn continues instead of
# ending. Note the precedence: STDERR FIRST, which is the opposite of what a
# "print your reason" instinct suggests. Exit 0 instead offers a JSON decision;
# every other exit code, including 2, produces no continuation at all.
#
# THE ONE-SHOT IS NOT OPTIONAL. Nothing stops a Stop hook that always exits 1
# from restarting the graph forever, and this fixture is meant to be run by hand
# in an interactive session. The sentinel path is printed in the injected text,
# so the operator reads how to re-arm it from inside the transcript.
#
# The reason is capped at 4000 characters and silently truncated beyond that, so
# keep the injected text short.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=probe-lib.sh
. "$here/probe-lib.sh"

marker="${1:?usage: probe-stop-loop.sh <marker>}"

payload="$(probe_slurp)"
probe_record "$marker" "$payload"

if probe_claim_once "$marker"; then
  printf 'PROBE %s injected this text and restarted the graph. Reply with the single line STOP-PROBE-ACK and then end your turn. This probe is one-shot; remove %s to re-arm it.\n' \
    "$marker" "$(probe_state_dir)/claim-$marker" >&2
  exit 1
fi

# Second and later calls: exit 0 with empty stdout. Exit 0 routes to the
# stop-decision JSON parser, which finds no decision in an empty stream, so the
# turn ends normally.
exit 0
