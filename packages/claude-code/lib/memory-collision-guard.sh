#!/usr/bin/env bash
# claude-memory-collision-guard — a PreToolUse hook that pauses the FIRST write to a
# given agent-memory file in a session and hands the model its neighbours first.
#
# ── The failure it prevents ─────────────────────────────────────────────────────
# Concurrent Claude Code sessions share one memory directory and neither sees the
# other's writes: no locking, no notification. A session reads the memory index once
# at start and then writes into a directory that may have moved underneath it. Two
# sessions on 2026-08-05 recorded the same concept under different filenames minutes
# apart and agreed only by luck. The failure is SILENT — a duplicate under a
# different name raises no conflict, it just quietly fails to be found, because the
# wikilink graph resolves by name.
#
# ── Why a hook and not an instruction ───────────────────────────────────────────
# Same argument delegationClamp.nix's header makes for a different surface: a
# standing instruction lands once, near the top, and loses position to everything
# said since. What decays is ATTENTION, not content. A hook fires at the point of
# action, which is the only place this check is worth anything — the model has to be
# holding the concept it is about to write.
#
# ── Two instrumentations were considered. This is the one we are trying ─────────
# Neither was measured; the choice is a gut check, deliberately made without
# building an observability harness first. Recorded so a future session can pivot
# on evidence rather than re-derive the trade-off:
#
#   A. allow + additionalContext (REACTIVE, not chosen)
#      Return permissionDecision "allow" with the neighbour listing in
#      `additionalContext`. Never blocks. But `additionalContext` reaches the model
#      on the NEXT request, so the write has already happened — the model can only
#      merge or delete the duplicate after the fact. Cheapest, and a duplicate that
#      exists for one turn is still fixable.
#
#   B. deny-once + permissionDecisionReason (PROACTIVE, chosen)
#      Deny the first write to each memory file per session, with the listing as the
#      denial reason, then allow the retry. Costs one extra round trip per distinct
#      file and needs marker state to terminate. Chosen because the failure it
#      prevents is silent and permanent while the cost is one retry, and because
#      delegationClamp.nix already proves the session-keyed marker shape works here.
#
# `permissionDecisionReason` was picked over `additionalContext` as the CHANNEL for
# a second reason worth keeping: on a deny, the reason is documented to be fed back
# to the model so it can adjust. Whether `additionalContext` is honoured on
# PreToolUse is less certain — the current docs say yes, but this repo's own
# typed-hooks research (docs/plans/typed-hooks-research/research-raw/
# lens-07-why-future-plans.md) enumerates it for Stop/PostToolUse/UserPromptSubmit/
# SessionStart and never for PreToolUse. Deny-with-reason needs neither claim to be
# true, so it is the channel that does not depend on resolving that disagreement.
#
# If evidence later says B nags more than it helps, A is a small edit: swap the
# decision to "allow", move the text to `additionalContext`, and drop the marker.
#
# ── Fail-open, and note this INVERTS delegationClamp's bias ─────────────────────
# The clamp degrades toward injecting, because losing its injection loses the
# mitigation. This degrades toward ALLOWING, and the asymmetry is load-bearing: a
# deny we failed to record repeats forever, so the model would retry into the same
# denial with no way through. A guard that cannot write its marker MUST let the
# write proceed. Every failure path here exits 0 silently.
# cspell:ignore nosession  (the literal fallback marker key, not project vocabulary)
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

# Baked at nix eval time by memoryCollisionGuard.nix; defaults keep the script
# runnable standalone (checks/claude-memory-collision-guard.nix drives it directly).
guard_root="${MEMORY_GUARD_ROOT:-${CLAUDE_CONFIG_DIR:-${HOME:-/nonexistent}/.claude}/projects}"
window_minutes="${MEMORY_GUARD_WINDOW_MINUTES:-10}"
list_count="${MEMORY_GUARD_LIST_COUNT:-10}"
extra_dirs="${MEMORY_GUARD_EXTRA_DIRS:-}"

envelope="$(cat)"

# jq must never be able to break a write. Every parse degrades to "not guarded".
file_path="$(jq -r '.tool_input.file_path // empty' <<<"$envelope" 2>/dev/null || :)"
session_id="$(jq -r '.session_id // empty' <<<"$envelope" 2>/dev/null || :)"

if [ -z "$file_path" ]; then
  exit 0
fi

# `realpath -m` normalizes without requiring existence — a Write creates the file,
# so it usually does not exist yet. Hooks run with cwd = project root, so a relative
# file_path resolves correctly here.
resolved="$(realpath -m -- "$file_path" 2>/dev/null || printf '%s' "$file_path")"

# Matched as a PATTERN rather than against a derived path. The memory directory is
# keyed by a slug of the session's cwd, so every worktree of one repo gets its own —
# deriving the exact path would need the slug rule and would silently miss whenever
# that rule changed. `<projects>/*/memory/*` holds regardless of slug.
guarded=0
case "$resolved" in
"$guard_root"/*/memory/*) guarded=1 ;;
*) : ;;
esac

if [ "$guarded" -eq 0 ] && [ -n "$extra_dirs" ]; then
  while IFS= read -r extra_dir; do
    if [ -n "$extra_dir" ]; then
      case "$resolved" in
      "$extra_dir"/*)
        guarded=1
        break
        ;;
      *) : ;;
      esac
    fi
  done <<<"$extra_dirs"
fi

if [ "$guarded" -eq 0 ]; then
  exit 0
fi

marker_dir="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/claude-memory-collision-guard"

# Keyed by session AND target, not by session alone: each distinct memory file is a
# separate collision risk, so each earns one pause. Keying by session alone would
# guard the first write of a session and wave through every later one.
if [ -z "$session_id" ]; then
  session_id=nosession
fi
session_id="${session_id//[^A-Za-z0-9._-]/_}"
# Hash rather than a sanitized path: memory paths run long enough to threaten the
# 255-byte filename limit. A collision only costs one skipped pause.
path_key="$(printf '%s' "$resolved" | sha256sum | cut -c1-16)"
marker="$marker_dir/${session_id}-${path_key}"

if [ -e "$marker" ]; then
  exit 0
fi

# Record BEFORE denying. If the marker cannot be written the guard must stand down
# entirely — see the fail-open note in the header. This is the one ordering in the
# script that is not merely defensive.
if mkdir -p "$marker_dir" 2>/dev/null; then
  chmod 700 "$marker_dir" 2>/dev/null || :
  # XDG_RUNTIME_DIR is tmpfs and clears on logout; the /tmp fallback accumulates.
  find "$marker_dir" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null || :
else
  exit 0
fi

if touch "$marker" 2>/dev/null; then
  :
else
  exit 0
fi

memory_dir="$(dirname -- "$resolved")"
now="$(date +%s)"
cutoff="$((now - window_minutes * 60))"

# Bounded read: filenames, mtimes, and the `description:` frontmatter line only. The
# bodies are never opened, so this cannot spill memory contents into a hook payload.
listing=""
recent_count=0
while IFS=$'\t' read -r epoch neighbour; do
  if [ -z "$neighbour" ]; then
    continue
  fi
  epoch_int="${epoch%.*}"
  stamp="$(date -d "@$epoch_int" '+%Y-%m-%d %H:%M' 2>/dev/null || printf 'unknown')"
  description="$(sed -n '1,20{/^description:/{s/^description:[[:space:]]*//;p;q;};}' -- "$neighbour" 2>/dev/null || :)"
  flag=""
  if [ "$epoch_int" -ge "$cutoff" ]; then
    flag="   <-- written in the last ${window_minutes}m"
    recent_count="$((recent_count + 1))"
  fi
  listing="${listing}  ${stamp}  $(basename -- "$neighbour")${flag}"$'\n'
  if [ -n "$description" ]; then
    listing="${listing}            ${description}"$'\n'
  fi
done < <(find "$memory_dir" -maxdepth 1 -type f -name '*.md' -printf '%T@\t%p\n' 2>/dev/null | sort -rn | head -n "$list_count")

if [ -z "$listing" ]; then
  listing="  (no existing memory files found in $memory_dir)"$'\n'
fi

concurrency_note="No memory file here was written in the last ${window_minutes} minutes."
if [ "$recent_count" -gt 0 ]; then
  concurrency_note="${recent_count} file(s) below were written in the last ${window_minutes} minutes. That is a CONCURRENT SESSION signal — it did not see your write and you did not see its."
fi

reason="Memory-collision guard: paused once before your first write to $(basename -- "$resolved") this session.

Concurrent sessions share this memory directory and no session sees another's writes. A duplicate saved under a DIFFERENT name raises no conflict — it silently fails to be found, because the wikilink graph resolves by name.

${concurrency_note}

${list_count} most recently modified files in ${memory_dir}:
${listing}
Decide one thing: does any file above already cover the concept you are about to record?
  - YES -> edit THAT file instead of creating a new one.
  - NO  -> re-issue this exact write. It will go through; this pause fires once per file per session."

jq -nc --arg reason "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason,
  },
}'

exit 0
