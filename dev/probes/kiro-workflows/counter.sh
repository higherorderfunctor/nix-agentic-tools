#!/usr/bin/env bash
# Counts real invocations, so no-op `repeat` iterations become detectable.
#
# One invocation == one unit of work. Appends an audit line, and on every
# invocation at or past the target count writes — and thereafter rewrites — the
# stop marker. The rewriting is deliberate, not an oversight: each write
# refreshes the recorded `count`, so an overshooting loop leaves the LATEST
# count in reached.json and the overshoot stays visible. Guarding the write to
# fire only on first reach would freeze the count at the target and destroy
# exactly the signal this fixture exists to produce. Compare this count against
# the `sequence:<repeatId>#<n>` wrapper nodes in `inspect_workflow`:
#
#   no-op iterations = engine iterations − invocations recorded here
#
# A step that leaves no filesystem trace cannot be audited this way at all,
# which is why every probe writes one (dev/references/kiro-workflows.md §4.4,
# §7.2).
#
# Usage: counter.sh <root> <target_count>
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

root="${1:?probe root directory required}"
target="${2:?target invocation count required}"

mkdir -p -- "$root"
log="$root/invocations.log"

now() {
  local t
  if [ -n "${EPOCHREALTIME:-}" ]; then
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

printf '%s invocation\n' "$(now)" >>"$log"
# `--` so a log path beginning with "-" is an operand, not a grep option.
count="$(grep -c -- invocation "$log" | tr -d ' ')"

if [ "$count" -ge "$target" ]; then
  printf '{"reached": true, "count": %s}\n' "$count" >"$root/reached.json"
  printf 'INVOCATION %s of %s — TARGET REACHED\n' "$count" "$target"
else
  printf 'INVOCATION %s of %s — more work remains\n' "$count" "$target"
fi
