#!/usr/bin/env bash
# Fails when any given patched source tree holds .orig or .rej files.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
artifacts=$(find -L "$@" \( -name '*.orig' -o -name '*.rej' \) -print)
test -z "$artifacts" || {
	printf '%s\n' "$artifacts" >&2
	exit 1
}
