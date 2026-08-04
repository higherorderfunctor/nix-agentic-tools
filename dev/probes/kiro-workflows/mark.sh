#!/usr/bin/env bash
# Durable timestamped marker for workflow probes.
#
# Writes a start line, optionally sleeps, then writes an end line and a JSON
# marker file. The start/end split is load-bearing: a branch the engine KILLS
# mid-flight leaves a start line with no end line and no JSON file, which is the
# only way to distinguish "aborted" from "finished but its result was discarded"
# (dev/references/kiro-workflows.md §7.7, §13).
#
# Usage: mark.sh <root> <name> [sleep_seconds]
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

root="${1:?probe root directory required}"
name="${2:?marker name required}"
sleep_for="${3:-0}"

mkdir -p -- "$root"

# Portable epoch timestamp. `date +%N` is GNU-only — BSD/macOS date emits a bare
# `N`, so the fallback strips it and degrades to whole seconds. See §13 for why
# whole-second resolution invalidates the peak-concurrency analysis.
now() {
  local t
  if [ -n "${EPOCHREALTIME:-}" ]; then # bash >= 5; locale may use a comma
    printf '%s\n' "${EPOCHREALTIME/,/.}"
    return 0
  fi
  t="$(date +%s.%N)"
  # shfmt owns this block's indentation. treefmt runs it WITHOUT `-ci`, so
  # patterns align with `case`/`esac`; indenting them is what `-ci` would do and
  # the next treefmt run reverts it. `shfmt -i 2 -d` on this file is clean.
  case "$t" in
  *.N) t="${t%.N}" ;; # no sub-second resolution available
  *) ;;               # already carries fractional seconds
  esac
  printf '%s\n' "$t"
}

printf '%s %s start\n' "$(now)" "$name" >>"$root/log"

if [ "$sleep_for" -gt 0 ]; then
  sleep "$sleep_for"
fi

printf '%s %s end\n' "$(now)" "$name" >>"$root/log"
printf '{"marker":"%s","done":true}\n' "$name" >"$root/$name.json"
printf 'MARKED %s\n' "$name"
