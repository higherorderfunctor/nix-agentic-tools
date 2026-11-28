# Hermetic branch-test for packages/claude-code/lib/memory-collision-guard.sh — the
# agent-memory collision guard. Exercises the scope test, the deny-once cadence, the
# per-file keying, and marker-directory permission repair.
{pkgs, ...}: {
  checks.claude-memory-collision-guard =
    pkgs.runCommandLocal "claude-memory-collision-guard-check" {
      nativeBuildInputs = [pkgs.coreutils pkgs.findutils pkgs.gnused pkgs.jq];
      src = ../lib/memory-collision-guard.sh;
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      cp "$src" guard.sh
      chmod +x guard.sh

      export XDG_RUNTIME_DIR="$PWD/run"
      mkdir -p "$XDG_RUNTIME_DIR"

      # A stand-in for <claude config>/projects/<slug>/memory/, which is what the script
      # matches as a pattern rather than as a computed path.
      export MEMORY_GUARD_ROOT="$PWD/projects"
      export MEMORY_GUARD_WINDOW_MINUTES=10
      export MEMORY_GUARD_LIST_COUNT=10
      mem="$MEMORY_GUARD_ROOT/proj-a/memory"
      mkdir -p "$mem"

      # Two neighbours: one stale, one written just now. The recent one is the concurrent
      # session signal the whole hook exists to surface.
      printf -- '---\nname: old-thing\ndescription: an older recorded fact\n---\nbody\n' > "$mem/old-thing.md"
      touch -d '2020-01-01 00:00' "$mem/old-thing.md"
      # A description carrying quotes, a backslash and an em dash — the exact shapes that
      # break hand-rolled JSON. jq -n --arg is what makes this safe; assert it.
      printf -- '---\nname: quoted\ndescription: "he said \\"hi\\" — path C:\\\\tmp"\n---\nbody\n' > "$mem/quoted.md"

      envelope() { printf '{"session_id":"%s","tool_name":"Write","tool_input":{"file_path":"%s"}}' "$1" "$2"; }
      run() {
        local input=$1
        shift
        rc=0
        got="$(printf '%s' "$input" | "$@" bash guard.sh 2>diagnostic)" || rc=$?
      }
      fail() { printf 'FAIL: %s (status=%s, output=%s)\n' "$1" "$rc" "$got" >&2; cat diagnostic >&2; exit 1; }
      passed() { printf 'ok - did not observe: %s\n' "$1"; }
      allows() {
        [[ $rc == 0 && -z $got ]] || fail "$1"
        [[ ! -s diagnostic ]] || fail "$1 (unexpected diagnostic)"
        passed "$1"
      }
      denies() {
        [[ $rc == 0 && ! -s diagnostic ]] || fail "$1"
        reason=$(jq -er '
          .hookSpecificOutput
          | select(.hookEventName == "PreToolUse" and .permissionDecision == "deny")
          | .permissionDecisionReason | strings | select(length > 0)
        ' <<<"$got") || fail "$1 (expected a deny with a reason)"
        passed "$1"
      }

      run "$(envelope sess-one "$PWD/somewhere/else.md")"
      allows "a non-memory write was intercepted"

      run "$(envelope sess-one "$mem/new-fact.md")"
      denies "first memory write did not pause"
      # Pin the timestamp-independent parts of both rows, including the exact
      # frontmatter text; parsing alone cannot detect dropped backslashes.
      while IFS= read -r line; do
        case "$line" in
          *'  old-thing.md') stale="$line" ;;
          *'  quoted.md   <-- written in the last 10m') recent="$line" ;;
        esac
      done <<<"$reason"
      [[ -n ''${stale:-} && -n ''${recent:-} ]] || fail "stale and recent neighbours were not distinguished"
      [[ $reason == *"an older recorded fact"* ]] || fail "listing lost an ordinary frontmatter description"
      expected='"he said \"hi\" — path C:\\tmp"'
      [[ $reason == *"$expected"* ]] || fail "quoted description did not round-trip through JSON"

      run "$(envelope sess-one "$mem/another-fact.md")"
      denies "marker keyed by session alone suppressed a different file"
      run "$(envelope sess-two "$mem/new-fact.md")"
      denies "marker keyed by path alone blocked the next session's pause"

      run '{}'
      allows "an envelope without a target blocked a write"

      outside="$PWD/elsewhere/store"
      mkdir -p "$outside"
      run "$(envelope sess-extra "$outside/thing.md")" env MEMORY_GUARD_EXTRA_DIRS="$outside"
      denies "extraDirectories failed to widen the guarded scope"

      # Removing write permission from the owned marker directory itself
      # takes the permission repair path.
      own_root="$PWD/own"
      own_markers="$own_root/claude-memory-collision-guard"
      mkdir -p "$own_markers"
      chmod 500 "$own_markers"
      run "$(envelope sess-own "$mem/own-fact.md")" env XDG_RUNTIME_DIR="$own_root"
      denies "an owned marker directory was not repaired"
      [[ $(stat -c %a "$own_markers") == 700 ]] || fail "marker directory mode was not restored"

      run "$(envelope '../../escape' "$mem/traversal.md")"
      denies "a session identifier with separators suppressed the pause"
      [[ -n $(find "$XDG_RUNTIME_DIR/claude-memory-collision-guard" -maxdepth 1 -name '.._.._escape-*' -type f -print -quit) ]] || fail "session_id was not sanitized into a flat marker"

      empty_mem="$MEMORY_GUARD_ROOT/proj-empty/memory"
      mkdir -p "$empty_mem"
      run "$(envelope sess-empty "$empty_mem/first.md")"
      denies "an empty directory suppressed the first-write pause"
      [[ $reason == *"(no existing memory files found in $empty_mem)"* ]] || fail "empty listing lacks an explanation"

      touch "$out"
    '';
}
