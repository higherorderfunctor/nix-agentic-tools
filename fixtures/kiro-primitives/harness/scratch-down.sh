#!/usr/bin/env bash
#
# Tear down a mode-F scratch environment.
#
# Refuses anything that is not under the scratch root. That guard is the whole
# point of the script: the harness deletes directories recursively, and a bug in
# a path variable must not be able to reach the operator's real ~/.kiro. The
# engine's own delete is likewise a recursive removal of one session directory,
# so there is nothing subtler to do here — only something safer.
#
# Usage: scratch-down.sh [--keep-logs]
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"

: "${KIRO_FIXTURE_SCRATCH:?nothing to tear down - KIRO_FIXTURE_SCRATCH is unset}"

keep_logs=0
if [ "${1:-}" = "--keep-logs" ]; then
  keep_logs=1
fi

scratch_root="$KIRO_FIXTURE_SCRATCH"

# Two independent guards. The first rejects a root that is unsafe on its face
# ($HOME, /, empty). The second re-derives the target and checks containment, so
# a later refactor that changes how the target is built still cannot escape.
kiro_assert_under_scratch "$scratch_root" "$scratch_root"

if [ ! -d "$scratch_root" ]; then
  printf 'nothing to do: %s does not exist\n' "$scratch_root"
  exit 0
fi

# Belt and braces: the real ~/.kiro must not be reachable from the target. This
# would only fire if the scratch root were mis-set to an ancestor of the real
# home, which is exactly the mistake worth being paranoid about.
case "$HOME/.kiro" in
"$scratch_root"/*)
  echo "refusing: the real ${HOME}/.kiro lies under the scratch root" >&2
  exit 1
  ;;
esac

if [ "$keep_logs" -eq 1 ]; then
  log_stash="${scratch_root%/}.logs-kept"
  if [ -d "$scratch_root/home/.kiro/logs" ]; then
    mkdir -p "$log_stash"
    cp -a "$scratch_root/home/.kiro/logs/." "$log_stash/"
    printf 'logs preserved at %s\n' "$log_stash"
  else
    printf 'no logs to preserve\n'
  fi
fi

# Report what is being removed before removing it. A teardown that prints
# nothing is a teardown nobody can audit after the fact.
printf 'removing scratch root: %s\n' "$scratch_root"
if [ -d "$scratch_root/home/.kiro/sessions" ]; then
  shopt -s nullglob
  for bucket_dir in "$scratch_root/home/.kiro/sessions"/*/; do
    for session_dir in "$bucket_dir"*/; do
      printf '  session: %s\n' "$(basename "${session_dir%/}")"
    done
  done
fi

rm -rf "$scratch_root"
printf 'done\n'
