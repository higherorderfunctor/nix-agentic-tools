# Hermetic branch-test for packages/claude-code/lib/memory-collision-guard.sh — the
# agent-memory collision guard. Exercises the scope test, the deny-once cadence, the
# per-file keying, and every fail-open path.
#
# The cadence is what this pins hardest, and for a sharper reason than the clamp's:
# this hook DENIES a tool call, so a deny that repeats is not a cost regression, it is
# a livelock. The model retries the same write, gets the same denial, and has no way
# through. Test 3 is therefore the load-bearing one — and test 8 covers the case where
# the marker cannot be written at all, where the script must stand down completely
# rather than deny without a memo.
#
# Note this INVERTS the clamp's degradation bias, which is why both directions are
# asserted explicitly: the clamp degrades toward injecting, this degrades toward
# allowing the write.
{pkgs, ...}:
pkgs.runCommandLocal "claude-memory-collision-guard-check" {
  nativeBuildInputs = [pkgs.coreutils pkgs.findutils pkgs.gnused pkgs.jq pkgs.shellcheck];
  src = ../packages/claude-code/lib/memory-collision-guard.sh;
} ''
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :

  outdir="$out"
  cp "$src" guard.sh
  chmod +x guard.sh
  shellcheck -x guard.sh   # lint gate (matches the -x pre-commit standard)

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

  pass=0; fail=0
  ok()  { pass=$((pass+1)); echo "ok   - $1"; }
  bad() { fail=$((fail+1)); echo "FAIL - $1" >&2; }

  # run <stdin> -> stdout in $got, exit status in $rc
  run() {
    set +e
    got="$(printf '%s' "$1" | bash guard.sh 2>/dev/null)"
    rc=$?
    set -e
  }
  envelope() { printf '{"session_id":"%s","tool_name":"Write","tool_input":{"file_path":"%s"}}' "$1" "$2"; }

  # 1. A path OUTSIDE any guarded directory is none of this hook's business.
  run "$(envelope sess-one "$PWD/somewhere/else.md")"
  if [ "$rc" -eq 0 ] && [ -z "$got" ]
  then ok "non-memory path is silent (write allowed)"
  else bad "non-memory path was not silent (rc=$rc got=$got)"
  fi

  # 2. First write to a memory file denies, with a valid PreToolUse decision.
  run "$(envelope sess-one "$mem/new-fact.md")"
  if [ "$rc" -eq 0 ] && printf '%s' "$got" | jq -e '
        .hookSpecificOutput.hookEventName == "PreToolUse"
        and .hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1
  then ok "first write to a memory file denies with valid PreToolUse JSON"
  else bad "first write did not produce a valid deny (rc=$rc got=$got)"
  fi
  first_reason="$(printf '%s' "$got" | jq -r '.hookSpecificOutput.permissionDecisionReason')"

  # 2b. The reason must actually carry the neighbours and their descriptions —
  #     an empty or truncated listing would deny without telling the model anything.
  if [ "''${first_reason#*old-thing.md}" != "$first_reason" ] \
     && [ "''${first_reason#*an older recorded fact}" != "$first_reason" ]
  then ok "denial reason lists neighbours and their description frontmatter"
  else bad "denial reason did not carry the neighbour listing"
  fi

  # 2c. The recent neighbour is flagged and the stale one is not. This is the
  #     concurrent-session signal; without the distinction the listing is just noise.
  if [ "''${first_reason#*written in the last}" != "$first_reason" ]
  then ok "a just-written neighbour is flagged as a concurrent-session signal"
  else bad "recent neighbour was not flagged"
  fi

  # 2d. A description containing quotes/backslashes must not corrupt the payload.
  #     (Test 2 already required the whole document to parse, so reaching here with
  #     the quoted text present proves the escaping rather than merely the parse.)
  if [ "''${first_reason#*he said}" != "$first_reason" ]
  then ok "quote/backslash-bearing description survives JSON serialization"
  else bad "quoted description did not round-trip into the reason"
  fi

  # 3. THE LOAD-BEARING ONE. The retry must go through. A second denial for the same
  #    file in the same session is a livelock, not a cost regression.
  run "$(envelope sess-one "$mem/new-fact.md")"
  if [ "$rc" -eq 0 ] && [ -z "$got" ]
  then ok "retry of the same file in the same session is allowed (no livelock)"
  else bad "same file denied twice — the model would retry into this forever"
  fi

  # 4. A DIFFERENT file in the same session earns its own pause: each new file is a
  #    separate collision risk, and keying by session alone would wave them through.
  run "$(envelope sess-one "$mem/another-fact.md")"
  if [ -n "$got" ]
  then ok "a different file in the same session is guarded independently"
  else bad "second distinct file was suppressed by the first file's marker"
  fi

  # 5. A different session is independent.
  run "$(envelope sess-two "$mem/new-fact.md")"
  if [ -n "$got" ]
  then ok "a second session guards independently"
  else bad "second session was suppressed by the first session's marker"
  fi

  # 6. Degraded envelopes must ALLOW, never deny. A guard that denies on malformed
  #    input blocks writes it cannot even explain.
  run 'not json{'
  if [ "$rc" -eq 0 ] && [ -z "$got" ]; then ok "malformed stdin allows the write"
  else bad "malformed stdin did not fail open (rc=$rc got=$got)"; fi
  run '{}'
  if [ "$rc" -eq 0 ] && [ -z "$got" ]; then ok "absent file_path allows the write"
  else bad "absent file_path did not fail open (rc=$rc got=$got)"; fi

  # 7. extraDirectories widens the scope beyond the default pattern.
  outside="$PWD/elsewhere/store"
  mkdir -p "$outside"
  set +e
  got="$(envelope sess-extra "$outside/thing.md" \
         | MEMORY_GUARD_EXTRA_DIRS="$outside" bash guard.sh 2>/dev/null)"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ] && [ -n "$got" ]
  then ok "extraDirectories brings an outside store into scope"
  else bad "extraDirectories did not widen scope (rc=$rc)"
  fi

  # 8. A marker directory that cannot be created must stand the guard down — the
  #    inverse of the clamp's bias, and the difference matters: a deny it cannot record
  #    repeats forever, so allowing is the only safe degradation.
  #
  #    The thing that must not be writable is the PARENT, and that is not a technicality.
  #    Making the marker directory itself mode 500 does not test this: the script
  #    restores its mode, which SUCCEEDS on a directory we own, so the guard
  #    recovers and correctly denies (8b pins that). The real hazard is a shared /tmp
  #    whose claude-memory-collision-guard/ belongs to another user — there chmod
  #    fails too. A read-only parent is the reachable stand-in for it.
  ro_root="$PWD/ro"
  mkdir -p "$ro_root"
  chmod 500 "$ro_root"
  if mkdir -p "$ro_root/.probe" 2>/dev/null; then
    # Writes are not actually restricted here (e.g. running as root) — the case this
    # test exists for is unreachable, so assert nothing rather than assert falsely.
    rmdir "$ro_root/.probe"
    echo "skip - read-only marker parent (writes not restricted in this sandbox)"
  else
    set +e
    got="$(envelope sess-ro "$mem/ro-fact.md" \
           | XDG_RUNTIME_DIR="$ro_root" bash guard.sh 2>/dev/null)"
    rc=$?
    set -e
    if [ "$rc" -eq 0 ] && [ -z "$got" ]
    then ok "marker dir that cannot be created stands the guard down (allows, no livelock)"
    else bad "marker dir that cannot be created denied without a memo (rc=$rc) — livelock risk"
    fi
  fi
  chmod 700 "$ro_root"

  # 8b. The counterpart: a marker directory WE own that has lost its mode is repaired
  #     rather than treated as fatal. Pinned because 8's rewrite hinges on it — if the
  #     chmod is ever dropped, this flips to a silent guard and 8 keeps passing.
  own_root="$PWD/own"
  mkdir -p "$own_root/claude-memory-collision-guard"
  chmod 500 "$own_root/claude-memory-collision-guard"
  set +e
  got="$(envelope sess-own "$mem/own-fact.md" \
         | XDG_RUNTIME_DIR="$own_root" bash guard.sh 2>/dev/null)"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ] && [ -n "$got" ]
  then ok "marker dir we own is chmod-repaired and the guard still fires"
  else bad "self-owned marker dir was not repaired (rc=$rc) — guard silently disabled"
  fi

  # 9. A traversal-shaped session_id is sanitized into a FLAT marker name.
  run "$(envelope '../../escape' "$mem/traversal.md")"
  if [ -n "$(find "$XDG_RUNTIME_DIR/claude-memory-collision-guard" -maxdepth 1 -name '.._.._escape-*' -print -quit)" ]
  then ok "path-separator session_id is sanitized into a flat marker name"
  else bad "session_id was not sanitized into the expected flat marker"
  fi

  # 10. An empty memory directory still produces a usable denial rather than a
  #     malformed one with a hole where the listing should be.
  empty_mem="$MEMORY_GUARD_ROOT/proj-empty/memory"
  mkdir -p "$empty_mem"
  run "$(envelope sess-empty "$empty_mem/first.md")"
  if [ "$rc" -eq 0 ] && printf '%s' "$got" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1
  then ok "empty memory directory still yields a well-formed denial"
  else bad "empty memory directory produced a malformed payload (rc=$rc got=$got)"
  fi

  echo "claude-memory-collision-guard: $pass passed, $fail failed"
  [ "$fail" -eq 0 ] || exit 1
  touch "$outdir"
''
