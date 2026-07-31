#!/usr/bin/env bash
#
# Non-perturbing probe for the triggers that never inject and never block:
# PostToolUse and the three PostFile* triggers. Their stdout is discarded and
# their exit code cannot block, so this script records to the log and emits
# nothing on either stream.
#
# Use this shape for anything that must not change the turn. The observation is
# the log record, not the conversation.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=probe-lib.sh
. "$here/probe-lib.sh"

marker="${1:?usage: probe-quiet.sh <marker>}"

payload="$(probe_slurp)"
probe_record "$marker" "$payload"
