#!/usr/bin/env bash
# patch-artifacts checks real helper outputs; leaked backups or rejects fail.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
artifacts=$(find -L "$@" \( -name '*.orig' -o -name '*.rej' \) -print)
test -z "$artifacts" || {
  printf '%s\n' "$artifacts" >&2
  exit 1
}
