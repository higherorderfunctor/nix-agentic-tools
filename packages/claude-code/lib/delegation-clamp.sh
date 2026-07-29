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
# Always exits 0. A non-zero UserPromptSubmit hook surfaces as an error to the user,
# and a mitigation that breaks the session is worse than one that quietly lapses.
# cspell:ignore nosession  (the literal fallback marker key, not project vocabulary)
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

mode="${1:-}"
: "${DELEGATION_CLAMP_PAYLOAD_FILE:?claude-delegation-clamp: payload path not baked in}"

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
  # `if`, not `[ -e ] && exit 0` — the latter evaluates to exit status 1 when the
  # marker is ABSENT, which under `set -e` kills the script on exactly the path that
  # is supposed to inject.
  if [ -e "$marker" ]; then
    exit 0
  fi
  # chmod separately rather than `mkdir -m`: with -p the mode applies only to the
  # deepest new directory (SC2174), and the directory usually already exists anyway —
  # this enforces the mode on both paths. The /tmp fallback is world-writable, so
  # 700 is what stops another local user from pre-creating markers and muting the hook.
  mkdir -p "$marker_dir"
  chmod 700 "$marker_dir" 2>/dev/null || :
  # Best-effort prune. XDG_RUNTIME_DIR is tmpfs and clears on logout, but the /tmp
  # fallback can accumulate one marker per session for months.
  find "$marker_dir" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null || :
  touch "$marker"
  cat -- "$DELEGATION_CLAMP_PAYLOAD_FILE"
  ;;
clear)
  rm -f "$marker"
  ;;
*)
  echo "claude-delegation-clamp: expected 'inject' or 'clear', got '${mode}'" >&2
  ;;
esac

exit 0
