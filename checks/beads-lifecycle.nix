# Isolated subprocess contracts for the devenv-owned Beads lifecycle.
# cspell:ignore NOSYSTEM
{
  lib,
  pkgs,
  ...
}: let
  cfg = {
    issuePrefix = "fixture";
    ledgerUrl = "file://@FIXTURE@/ledger.git";
    package = pkgs.ai.devTools.beads;
    port = 13307;
    publishIntervalSeconds = 30;
  };
  lifecycle = import ../packages/beads/lib/mkLifecycle.nix {inherit cfg lib pkgs;};
in
  pkgs.runCommandLocal "beads-lifecycle-check" {
    nativeBuildInputs = [
      cfg.package
      cfg.package.dolt
      pkgs.coreutils
      pkgs.diffutils
      pkgs.git
      pkgs.gnugrep
      pkgs.gnused
      pkgs.jq
    ];
  } ''
    fail() {
      printf 'beads-lifecycle: %s\n' "$1" >&2
      exit 1
    }

    wait_for_ref() {
      local ledger="$1" attempt
      for attempt in $(seq 1 120); do
        if git -C "$ledger" rev-parse --verify refs/dolt/data >/dev/null 2>&1; then
          return
        fi
        sleep 0.1
      done
      fail "publisher did not drain refs/dolt/data"
    }

    stop_process() {
      local pid="$1"
      if kill -0 "$pid" 2>/dev/null; then
        kill "$pid"
        wait "$pid" 2>/dev/null || :
      fi
    }

    run_scenario() {
      local actor_id actual_ref before_ref database db_path dirty_head fixture label lifecycle_script linked_snapshot origin_mode publisher_pid server_pid source_snapshot state_root
      label="$1"
      origin_mode="$2"
      fixture="$TMPDIR/$label"
      lifecycle_script="$fixture/beads-lifecycle"
      mkdir -p "$fixture/home" "$fixture/state"
      cp ${lib.getExe' lifecycle.lifecycle "beads-lifecycle"} "$lifecycle_script"
      sed -i "s|@FIXTURE@|$fixture|g" "$lifecycle_script"
      chmod +x "$lifecycle_script"

      export GIT_CONFIG_GLOBAL="$fixture/home/.gitconfig"
      export GIT_CONFIG_NOSYSTEM=1
      export HOME="$fixture/home"
      export XDG_STATE_HOME="$fixture/state"
      git config --global user.email fixture@example.invalid
      git config --global user.name Fixture

      git init -q --bare "$fixture/ledger.git"
      git init -q -b main "$fixture/source"
      git -C "$fixture/source" commit -q --allow-empty -m seed
      if [ "$origin_mode" = equal ]; then
        git -C "$fixture/source" remote add origin "file://$fixture/ledger.git"
        git -C "$fixture/source" push -q origin main
      else
        git init -q --bare "$fixture/source-origin.git"
        git -C "$fixture/source" remote add origin "file://$fixture/source-origin.git"
        git -C "$fixture/source" push -q origin main
        git -C "$fixture/source" push -q "file://$fixture/ledger.git" main:main
      fi
      git -C "$fixture/source" worktree add -q -b linked "$fixture/linked"
      git -C "$fixture/source" status --short --untracked-files=all >"$fixture/source.status.before"
      git -C "$fixture/source" config --local --list | sort >"$fixture/source.config.before"
      git -C "$fixture/linked" status --short --untracked-files=all >"$fixture/linked.status.before"
      git -C "$fixture/linked" config --local --list | sort >"$fixture/linked.config.before"

      (cd "$fixture/source" && "$lifecycle_script" prepare)
      if git -C "$fixture/ledger.git" rev-parse --verify refs/dolt/data >/dev/null 2>&1; then
        fail "$label prepare published the ledger"
      fi
      [ ! -e "$fixture/home/.dolt" ] || fail "$label mutated user-global Dolt config"

      (cd "$fixture/source" && "$lifecycle_script" server) >"$fixture/server.out" 2>&1 &
      server_pid="$!"
      trap 'stop_process "$server_pid"' RETURN
      for _attempt in $(seq 1 120); do
        if (cd "$fixture/source" && "$lifecycle_script" bootstrap) >"$fixture/bootstrap.out" 2>&1; then
          break
        fi
        sleep 0.1
      done
      grep -Fq "initialized module-owned Beads state" "$fixture/bootstrap.out" \
        || fail "$label module-owned bootstrap did not initialize"
      (cd "$fixture/linked" && "$lifecycle_script" bootstrap) >"$fixture/reentry.out"
      grep -Fq "verified existing module-owned Beads state" "$fixture/reentry.out" \
        || fail "$label existing-state re-entry bootstrapped again"

      actor_id="$(cd "$fixture/source" && "$lifecycle_script" bd --actor human create "$label source issue" --silent)"
      (cd "$fixture/linked" && "$lifecycle_script" bd --actor codex create "$label linked issue" --silent) >/dev/null
      (cd "$fixture/linked" && "$lifecycle_script" bd show "$actor_id" --json) >/dev/null
      if (cd "$fixture/source" && "$lifecycle_script" bd dolt push) >"$fixture/forbidden.out" 2>&1; then
        fail "$label guarded bd accepted its own publisher command"
      fi
      grep -Fq "outside the guarded repository mutation surface" "$fixture/forbidden.out" \
        || fail "$label guarded bd rejected dolt push for the wrong reason"

      (cd "$fixture/source" && "$lifecycle_script" publisher) >"$fixture/publisher.out" 2>&1 &
      publisher_pid="$!"
      wait_for_ref "$fixture/ledger.git"
      stop_process "$publisher_pid"
      actual_ref="$(git -C "$fixture/ledger.git" rev-parse refs/dolt/data)"
      [ -n "$actual_ref" ] || fail "$label startup drain produced an empty ref"

      state_root="$(cd "$fixture/source" && "$lifecycle_script" status | jq -er .stateRoot)"
      [ "$state_root" = "$(cd "$fixture/linked" && "$lifecycle_script" status | jq -er .stateRoot)" ] \
        || fail "$label linked worktree did not share lifecycle state"
      database="$(cd "$fixture/source" && "$lifecycle_script" status | jq -er .database)"
      db_path="$state_root/dolt-data/$database"

      before_ref="$actual_ref"
      git -C "$fixture/ledger.git" update-ref refs/dolt/data refs/heads/main
      if (cd "$fixture/linked" && "$lifecycle_script" publish-once) >"$fixture/divergence.out" 2>&1; then
        fail "$label pusher accepted divergent remote history"
      fi
      grep -Fq "diverged" "$fixture/divergence.out" \
        || fail "$label pusher rejected divergence for the wrong reason"
      git -C "$fixture/ledger.git" update-ref refs/dolt/data "$before_ref"

      (
        cd "$db_path"
        DOLT_ROOT_PATH="$state_root/dolt-root" ${cfg.package.dolt}/bin/dolt \
          sql -r json -q "UPDATE issues SET notes = 'dirty fixture residue' WHERE id = '$actor_id';" \
          >/dev/null
      )
      dirty_head="$(
        cd "$db_path"
        DOLT_ROOT_PATH="$state_root/dolt-root" ${cfg.package.dolt}/bin/dolt \
          sql -r json -q 'SELECT COUNT(*) AS n FROM dolt_status' \
          | jq -er '.rows[0].n'
      )"
      [ "$dirty_head" -ge 1 ] || fail "$label did not create dirty residue"
      before_ref="$(git -C "$fixture/ledger.git" rev-parse refs/dolt/data)"
      if (cd "$fixture/source" && "$lifecycle_script" bd create "must not execute" --silent) \
        >"$fixture/dirty-client.out" 2>&1; then
        fail "$label guarded client accepted dirty incoming state"
      fi
      grep -Fq "dirty Dolt working set" "$fixture/dirty-client.out" \
        || fail "$label guarded client rejected dirty state for the wrong reason"
      if (cd "$fixture/linked" && "$lifecycle_script" publish-once) \
        >"$fixture/dirty-pusher.out" 2>&1; then
        fail "$label pusher accepted dirty incoming state"
      fi
      [ "$(git -C "$fixture/ledger.git" rev-parse refs/dolt/data)" = "$before_ref" ] \
        || fail "$label dirty refusal changed the remote ref"

      git -C "$fixture/source" status --short --untracked-files=all >"$fixture/source.status.after"
      git -C "$fixture/source" config --local --list | sort >"$fixture/source.config.after"
      git -C "$fixture/linked" status --short --untracked-files=all >"$fixture/linked.status.after"
      git -C "$fixture/linked" config --local --list | sort >"$fixture/linked.config.after"
      cmp "$fixture/source.status.before" "$fixture/source.status.after" \
        || fail "$label changed the source checkout"
      cmp "$fixture/source.config.before" "$fixture/source.config.after" \
        || fail "$label changed source local Git config"
      cmp "$fixture/linked.status.before" "$fixture/linked.status.after" \
        || fail "$label changed the linked checkout"
      cmp "$fixture/linked.config.before" "$fixture/linked.config.after" \
        || fail "$label changed linked local Git config"
      [ ! -e "$fixture/home/.dolt" ] || fail "$label mutated user-global Dolt config"

      stop_process "$server_pid"
      trap - RETURN
      printf '%s=%s\n' "$label" passed
    }

    test -x ${lifecycle.package}/bin/bd || fail "guarded bd is not installed"
    for entry in beads-bootstrap beads-checkpoint beads-diagnostics beads-publish beads-status; do
      test -x ${lifecycle.package}/bin/"$entry" || fail "$entry is not installed"
    done
    ${pkgs.gnugrep}/bin/grep -Fq 'push --set-upstream origin main' ${lib.getExe' lifecycle.lifecycle "beads-lifecycle"} \
      || fail "raw Dolt pusher is absent"
    if ${pkgs.gnugrep}/bin/grep -Fq -- '--force' ${lib.getExe' lifecycle.lifecycle "beads-lifecycle"}; then
      fail "lifecycle contains a force operation"
    fi

    run_scenario equal-origin equal
    run_scenario isolated-origin different
    touch "$out"
  ''
