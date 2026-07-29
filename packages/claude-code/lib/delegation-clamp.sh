#!/usr/bin/env bash
# claude-delegation-clamp — mitigation for Claude Code's `heron_brook` system-prompt
# section, which suppresses subagent and workflow use on a MODEL-capability gate with
# no user-facing off switch. See packages/claude-code/docs/heron-brook-clamp.md.
#
# Two modes, each reading a Claude Code hook envelope as JSON on stdin:
#
#   inject  (UserPromptSubmit) — emit the standing-request payload ONCE per session,
#                                then stay silent for the rest of it.
#   clear   (PreCompact)       — drop the marker so the next turn re-injects, because
#                                compaction is the one event that erases the original.
#
# The payload is serialized at NIX EVAL TIME into its own store file, whose absolute
# path arrives as DELEGATION_CLAMP_PAYLOAD_FILE — nothing is built by string
# concatenation here. A separate FILE rather than a baked-in string literal: inlining
# the JSON into this script put quotes and backslashes in a shell assignment (SC2089 /
# SC2090) and put non-ASCII text where shellcheck had to render it under a C locale,
# which crashes it with an unreadable `commitBuffer: invalid argument` instead of a
# diagnostic.
#
# Always exits 0, and that is a hard contract rather than a nicety: a non-zero
# UserPromptSubmit hook surfaces as an error to the user on EVERY turn, so a mitigation
# that breaks the session is worse than one that quietly lapses. Under `set -e` that
# means every filesystem call below must be explicitly best-effort — an unguarded
# `mkdir`/`touch`/`rm`/`cat` is a latent per-turn error dialog, not a nicety either.
# cspell:ignore nosession  (the literal fallback marker key, not project vocabulary)
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

mode="${1:-}"

marker_dir="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/claude-delegation-clamp"

# session_id keys the marker. jq must not be able to kill the hook, so a parse failure
# (malformed stdin, absent key, no stdin at all) degrades to a FIXED key rather than to
# "inject every turn" — the latter would silently restore the per-turn cumulative context
# growth that the once-per-session cadence exists to avoid.
session_id="$(jq -r '.session_id // empty' 2>/dev/null || :)"
[ -n "$session_id" ] || session_id=nosession
# A session_id is an opaque server-issued string, so sanitize before joining it onto a
# path — no traversal, no surprises.
session_id="${session_id//[^A-Za-z0-9._-]/_}"

marker="$marker_dir/$session_id"

case "$mode" in
inject)
  # A broken wrapper (payload path unset, or the store file unreadable) leaves nothing
  # to inject. Lapse quietly with a stderr breadcrumb rather than aborting non-zero —
  # same contract as every other failure path here.
  payload_file="${DELEGATION_CLAMP_PAYLOAD_FILE:-}"
  if [ -z "$payload_file" ] || [ ! -r "$payload_file" ]; then
    echo "claude-delegation-clamp: payload file missing or unreadable; skipping" >&2
    exit 0
  fi
  # `if`, not `[ -e ] && exit 0` — the latter evaluates to exit status 1 when the
  # marker is ABSENT, which under `set -e` kills the script on exactly the path that
  # is supposed to inject.
  if [ -e "$marker" ]; then
    exit 0
  fi
  # Marker bookkeeping is entirely best-effort, and the injection happens either way.
  # The realistic failure is a shared /tmp whose claude-delegation-clamp/ directory is
  # owned by another user — reachable whenever neither XDG_RUNTIME_DIR nor TMPDIR is
  # set. Losing the once-per-session cadence costs ~75 tokens per turn; losing the
  # injection costs the mitigation itself, which is the failure this feature exists to
  # prevent. So a marker we cannot write degrades toward injecting, never toward
  # silence.
  #
  # chmod separately rather than `mkdir -m`: with -p the mode applies only to the
  # deepest new directory (SC2174), and the directory usually already exists anyway.
  if mkdir -p "$marker_dir" 2>/dev/null; then
    chmod 700 "$marker_dir" 2>/dev/null || :
    # Prune. XDG_RUNTIME_DIR is tmpfs and clears on logout, but the /tmp fallback can
    # accumulate one marker per session for months.
    find "$marker_dir" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null || :
    touch "$marker" 2>/dev/null || :
  fi
  cat -- "$payload_file" 2>/dev/null || :
  ;;
clear)
  rm -f "$marker" 2>/dev/null || :
  ;;
*)
  echo "claude-delegation-clamp: expected 'inject' or 'clear', got '${mode}'" >&2
  ;;
esac

exit 0
