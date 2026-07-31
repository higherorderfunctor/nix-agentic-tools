#!/usr/bin/env bash
#
# Observed probe for the two triggers that BYPASS the decision function:
# SessionStart and UserPromptSubmit. Both inject stdout into the conversation on
# ANY exit code, so this script's stdout is the observation.
#
# NOTHING IS WRITTEN TO STDERR ON ANY PATH. When stdout is empty those two
# triggers promote stderr into the conversation instead, so a progress line on
# stderr would become model-visible text. An error from bash or from a failing
# helper still reaches stderr, which is wanted: a broken probe should be loud.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=probe-lib.sh
. "$here/probe-lib.sh"

marker="${1:?usage: probe-inject.sh <marker>}"

payload="$(probe_slurp)"
probe_record "$marker" "$payload"

printf 'PROBE %s fired; payload appended to %s\n' "$marker" "$(probe_log_path)"
