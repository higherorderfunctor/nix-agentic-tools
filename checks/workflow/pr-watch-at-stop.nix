# Hermetic branch-test for lib/pr-watch-at-stop.sh — the Stop hook that refuses
# a hand-back while this branch's PR is unfinished.
#
# It drives the REAL script against a STUB `gh`, so what is exercised is the
# decision logic and the fail-open paths, not GitHub. That split matters: the
# fail-open paths are the ones that cannot be tested against a live API at all
# (no `gh` on PATH, no upstream, a timeout), and they are also the ones whose
# regression is worst — a hook that blocks because the network hiccuped is
# worse than the failure it prevents, and unlike the lint validator this one
# cannot be satisfied by editing a file.
{pkgs, ...}: {
  checks.pr-watch-at-stop =
    pkgs.runCommandLocal "pr-watch-at-stop-check" {
      nativeBuildInputs = [pkgs.coreutils pkgs.git pkgs.python3 pkgs.shellcheck];
      src = ../../lib/pr-watch-at-stop.sh;
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      outdir="$out"
      export HOME="$PWD/home"; mkdir -p "$HOME"
      git config --global user.email a@b.c
      git config --global user.name a
      git config --global init.defaultBranch main

      shellcheck --shell=bash "$src"

      mkdir -p bin repo
      REAL_PATH="$PATH"          # PATH without the gh stub, for the no-gh case below
      export PATH="$PWD/bin:$PATH"

      # --- stub gh: prints whatever PR_JSON holds, or fails like "no PR here" ---
      # Shebang resolved at build time — the nix sandbox has no /usr/bin/env.
      # printf, not a heredoc: Nix strips the common indentation from this string,
      # so a heredoc body plus a compensating `sed` de-indents twice and silently
      # emits a mangled script. That failure is invisible — the stub then exits
      # non-zero, the hook reads it as "no PR", and every allow-case passes
      # VACUOUSLY while only the block-cases fail.
      {
        command -v bash | sed 's|^|#!|'
        echo 'if [ -n "''${PR_JSON:-}" ]; then printf "%s" "$PR_JSON"; exit 0; fi'
        echo 'exit 1'
      } > bin/gh
      chmod +x bin/gh
      # Positive control on the stub itself, for exactly the reason above.
      PR_JSON=probe bin/gh | grep -qx probe

      cd repo
      git init -q .
      git commit -q --allow-empty -m init
      # An upstream must exist or the hook exits before ever calling gh.
      git branch -q -M feat/x
      git remote add origin ../fake.git
      mkdir -p ../fake.git && git -C ../fake.git init -q --bare
      git push -q origin feat/x 2>/dev/null
      git branch -q --set-upstream-to=origin/feat/x feat/x

      # expect NAME PR_JSON [REASON [STOP_HOOK_ACTIVE [CWD]]]
      # No reason means the hook must exit successfully without blocking.
      expect() {
        local name="$1" json="$2" reason="''${3:-}" input got rc=0
        input="$(printf '{"stop_hook_active": %s, "cwd": "%s"}' "''${4:-false}" "''${5:-$PWD}")"
        got="$(PR_JSON="$json" bash "$src" <<< "$input")" || rc=$?
        if [ "$rc" -ne 0 ]; then
          echo "FAIL [$name]: expected exit 0, got $rc: $got" >&2; exit 1
        fi
        if [ -z "$reason" ]; then
          if [ -n "$got" ]; then echo "FAIL [$name]: expected no block, got: $got" >&2; exit 1; fi
        elif ! python3 -c '
      import json, sys
      result = json.load(sys.stdin)
      sys.exit(not (result["decision"] == "block" and sys.argv[1] in result["reason"]))
      ' "$reason" <<< "$got"; then
          echo "FAIL [$name]: expected block with '$reason', got: $got" >&2; exit 1
        fi
        echo "ok [$name]"
      }

      pr() { # NUMBER STATE MERGE_STATUS ROLLUP [THREADS]
        printf '{"number":%s,"state":"%s","isDraft":false,"mergeStateStatus":"%s","statusCheckRollup":%s,"reviewThreads":{"nodes":%s}}' \
          "$1" "$2" "$3" "$4" "''${5:-[]}"
      }
      green='[{"name":"test","status":"COMPLETED","conclusion":"SUCCESS"}]'
      red='[{"name":"test","status":"COMPLETED","conclusion":"FAILURE"}]'
      red_pr="$(pr 2 OPEN BLOCKED "$red")"

      # A conflicted PR schedules ZERO checks, so an empty rollup reads exactly like
      # "CI has not started". The block must say rebase, not wait.
      expect conflicted "$(pr 4 OPEN DIRTY '[]')" 'rebase onto the base branch and force-push, do not wait'

      # A finished PR must NOT block — without this the others pass for a hook that
      # always blocks, which would be indistinguishable and useless.
      expect green "$(pr 1 OPEN CLEAN "$green")"

      # Not OPEN: nothing to finish, even with a failing check.
      expect merged "$(pr 2 MERGED BLOCKED "$red")"
      expect red "$red_pr" 'these checks are RED: test'

      # The case that actually failed in practice: the agent pushed and ended the
      # turn while CI was still running.
      expect running "$(pr 3 OPEN BLOCKED '[{"name":"build","status":"IN_PROGRESS"}]')" \
        'these checks are still running: build - arm a watcher'
      expect threads "$(pr 5 OPEN BLOCKED "$green" '[{"isResolved":false}]')" '1 review thread(s) are unresolved'

      # --- fail-open paths, using the same red PR that blocks above where possible ---
      # loop guard: Claude re-runs Stop hooks after a block
      expect loop-guard "$red_pr" "" true

      # no gh on PATH at all. Drop ONLY the stub directory — an earlier version
      # built a minimal PATH by hand and left out bash itself, so the hook never
      # ran and the case passed for the wrong reason.
      PATH="$REAL_PATH" command -v bash >/dev/null
      if PATH="$REAL_PATH" command -v gh >/dev/null; then
        echo 'FAIL [no-gh]: gh is still on PATH' >&2; exit 1
      fi
      PATH="$REAL_PATH" expect no-gh "$red_pr"

      # no PR for this branch (stub gh exits non-zero)
      expect no-pr ""

      # not a git work tree
      expect no-repo "$red_pr" "" false /

      mkdir -p "$outdir"; touch "$outdir/ok"
    '';
}
