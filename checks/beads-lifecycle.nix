# Isolated subprocess contracts for the devenv-owned Beads lifecycle.
# cspell:ignore NOSYSTEM
{
  lib,
  pkgs,
  self,
  ...
}: let
  cfg = {
    issuePrefix = "fixture";
    ledgerUrl = "file://@FIXTURE@/ledger.git";
    package = pkgs.ai.devTools.beads;
    port = 13307;
    publishIntervalSeconds = 1;
  };
  lifecycle = import ../packages/beads/lib/mkLifecycle.nix {inherit cfg lib pkgs;};
in
  pkgs.runCommandLocal "beads-lifecycle-check" {
    __darwinAllowLocalNetworking = true;
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

    wait_for_ref_change() {
      local ledger="$1" before="$2" log_file="$3" actual attempt
      for attempt in $(seq 1 120); do
        actual="$(git -C "$ledger" rev-parse --verify refs/dolt/data 2>/dev/null || :)"
        if [ -n "$actual" ] && [ "$actual" != "$before" ]; then
          return
        fi
        sleep 0.1
      done
      cat "$log_file" >&2
      fail "publisher did not advance refs/dolt/data"
    }

    find_free_port() {
      local candidate first
      first="$((43000 + ($$ % 1000)))"
      for candidate in $(seq "$first" "$((first + 249))"); do
        if ! ${pkgs.coreutils}/bin/timeout 1 ${pkgs.bash}/bin/bash -c \
          "exec 3<>/dev/tcp/127.0.0.1/$candidate" >/dev/null 2>&1; then
          printf '%s\n' "$candidate"
          return
        fi
      done
      fail "could not find an unused loopback port"
    }

    wait_for_port() {
      local attempt port="$1"
      for attempt in $(seq 1 120); do
        if ${pkgs.coreutils}/bin/timeout 1 ${pkgs.bash}/bin/bash -c \
          "exec 3<>/dev/tcp/127.0.0.1/$port" >/dev/null 2>&1; then
          return
        fi
        sleep 0.1
      done
      fail "listener did not become ready"
    }

    stop_process() {
      local pid="$1"
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid"
        wait "$pid" 2>/dev/null || :
      fi
    }

    run_scenario() {
      local actor_id actual_ref before_ref client_pid cold_server_pid database db_path dirty_head entry entry_dir fixture foreign_pid holder_pid interval_id label lifecycle_script linked_id lock_path origin_mode port publish_pid publisher_pid server_pid startup_ref state_hash state_root
      label="$1"
      origin_mode="$2"
      fixture="$TMPDIR/$label"
      lifecycle_script="$fixture/beads-lifecycle"
      entry_dir="$fixture/bin"
      cold_server_pid=""
      foreign_pid=""
      publisher_pid=""
      server_pid=""
      port="$(find_free_port)"
      mkdir -p "$fixture/home" "$fixture/state"
      cp ${lib.getExe' lifecycle.lifecycle "beads-lifecycle"} "$lifecycle_script"
      sed -i "s|@FIXTURE@|$fixture|g" "$lifecycle_script"
      sed -i "s|13307|$port|g" "$lifecycle_script"
      chmod +x "$lifecycle_script"
      mkdir -p "$entry_dir"
      for entry in bd beads-bootstrap beads-checkpoint beads-diagnostics beads-publish beads-status; do
        cp ${lifecycle.package}/bin/"$entry" "$entry_dir/$entry"
        sed -i \
          "s|${lib.getExe' lifecycle.lifecycle "beads-lifecycle"}|$lifecycle_script|g" \
          "$entry_dir/$entry"
        chmod +x "$entry_dir/$entry"
      done

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

      mkdir -p "$fixture/runtime-a" "$fixture/runtime-b"
      (cd "$fixture/source" && XDG_RUNTIME_DIR="$fixture/runtime-a" "$lifecycle_script" prepare) &
      client_pid="$!"
      (cd "$fixture/linked" && XDG_RUNTIME_DIR="$fixture/runtime-b" "$lifecycle_script" prepare) &
      publish_pid="$!"
      wait "$client_pid"
      wait "$publish_pid"
      if git -C "$fixture/ledger.git" rev-parse --verify refs/dolt/data >/dev/null 2>&1; then
        fail "$label prepare published the ledger"
      fi
      [ ! -e "$fixture/home/.dolt" ] || fail "$label mutated user-global Dolt config"

      # A live but unowned listener must be rejected before module-owned
      # initialization can send any request to it.
      mkdir -p "$fixture/foreign-data" "$fixture/foreign-root"
      DOLT_ROOT_PATH="$fixture/foreign-root" ${cfg.package.dolt}/bin/dolt \
        config --global --add user.email fixture@example.invalid
      DOLT_ROOT_PATH="$fixture/foreign-root" ${cfg.package.dolt}/bin/dolt \
        config --global --add user.name Fixture
      (
        cd "$fixture/foreign-data"
        DOLT_ROOT_PATH="$fixture/foreign-root" ${cfg.package.dolt}/bin/dolt init >/dev/null
        DOLT_ROOT_PATH="$fixture/foreign-root" ${cfg.package.dolt}/bin/dolt \
          sql-server --host 127.0.0.1 --port "$port"
      ) >"$fixture/foreign-server.out" 2>&1 &
      foreign_pid="$!"
      trap 'stop_process "$publisher_pid"; stop_process "$cold_server_pid"; stop_process "$foreign_pid"; stop_process "$server_pid"' RETURN
      wait_for_port "$port"
      if (cd "$fixture/source" && "$entry_dir/beads-bootstrap") \
        >"$fixture/foreign-bootstrap.out" 2>&1; then
        fail "$label bootstrap accepted an unowned listener"
      fi
      grep -Fq "module-owned Dolt daemon is not ready" "$fixture/foreign-bootstrap.out" \
        || fail "$label rejected the foreign listener for the wrong reason"
      [ ! -e "$fixture/foreign-data/beads_fixture" ] \
        || fail "$label foreign listener received a database mutation"
      if (cd "$fixture/source" && "$lifecycle_script" server) \
        >"$fixture/foreign-port.out" 2>&1; then
        fail "$label server accepted a foreign port collision"
      fi
      grep -Fq "another process is already listening" "$fixture/foreign-port.out" \
        || fail "$label server rejected the foreign port for the wrong reason"
      stop_process "$foreign_pid"
      foreign_pid=""

      (cd "$fixture/source" && "$lifecycle_script" server) >"$fixture/server.out" 2>&1 &
      server_pid="$!"
      for _attempt in $(seq 1 120); do
        if (cd "$fixture/source" && "$entry_dir/beads-bootstrap") >"$fixture/bootstrap.out" 2>&1; then
          break
        fi
        sleep 0.1
      done
      grep -Fq "initialized module-owned Beads state" "$fixture/bootstrap.out" \
        || fail "$label module-owned bootstrap did not initialize"
      (cd "$fixture/linked" && "$entry_dir/beads-bootstrap") >"$fixture/reentry.out"
      grep -Fq "verified existing module-owned Beads state" "$fixture/reentry.out" \
        || fail "$label existing-state re-entry bootstrapped again"

      state_root="$(cd "$fixture/source" && "$entry_dir/beads-status" | jq -er .stateRoot)"
      state_hash="''${state_root##*/}"
      lock_path="$fixture/state/nix-agentic-tools/beads-locks/$state_hash.lock"
      (
        exec 9<>"$lock_path"
        ${pkgs.util-linux}/bin/flock 9
        touch "$fixture/lock-held"
        while [ ! -e "$fixture/release-lock" ]; do sleep 0.02; done
      ) &
      holder_pid="$!"
      while [ ! -e "$fixture/lock-held" ]; do sleep 0.02; done
      (cd "$fixture/source" && XDG_RUNTIME_DIR="$fixture/runtime-a" \
        "$entry_dir/bd" --actor human create "$label source issue" --silent) \
        >"$fixture/actor-id" &
      client_pid="$!"
      (cd "$fixture/linked" && XDG_RUNTIME_DIR="$fixture/runtime-b" \
        "$entry_dir/beads-checkpoint") >"$fixture/contended-checkpoint.out" &
      publish_pid="$!"
      sleep 1
      kill -0 "$client_pid" 2>/dev/null || fail "$label guarded mutation bypassed the repository lock"
      kill -0 "$publish_pid" 2>/dev/null || fail "$label checkpoint bypassed the repository lock"
      [ ! -s "$fixture/actor-id" ] || fail "$label guarded mutation produced output while the lock was held"
      [ ! -s "$fixture/contended-checkpoint.out" ] \
        || fail "$label checkpoint produced output while the lock was held"
      touch "$fixture/release-lock"
      wait "$holder_pid"
      wait "$client_pid"
      wait "$publish_pid"
      actor_id="$(cat "$fixture/actor-id")"

      linked_id="$(cd "$fixture/linked" && "$entry_dir/bd" --actor codex create "$label linked issue" --silent)"
      (cd "$fixture/linked" && "$entry_dir/bd" show "$actor_id" --json) >/dev/null
      if (cd "$fixture/source" && "$entry_dir/bd" dolt push) >"$fixture/forbidden.out" 2>&1; then
        fail "$label guarded bd accepted its own publisher command"
      fi
      grep -Fq "outside the guarded repository mutation surface" "$fixture/forbidden.out" \
        || fail "$label guarded bd rejected dolt push for the wrong reason"
      if (cd "$fixture/source" && "$entry_dir/bd" metrics on) >"$fixture/metrics.out" 2>&1; then
        fail "$label guarded bd accepted a user-global metrics mutation"
      fi
      if (cd "$fixture/source" && "$entry_dir/bd" rename-prefix changed --repair) \
        >"$fixture/rename-prefix.out" 2>&1; then
        fail "$label guarded bd accepted prefix repair"
      fi
      [ ! -e "$fixture/home/.config/bd/config.yaml" ] \
        || fail "$label mutated user-global Beads metrics config"

      before_ref=absent
      rm -f "$fixture/lock-held" "$fixture/release-lock"
      (
        exec 9<>"$lock_path"
        ${pkgs.util-linux}/bin/flock 9
        touch "$fixture/lock-held"
        while [ ! -e "$fixture/release-lock" ]; do sleep 0.02; done
      ) &
      holder_pid="$!"
      while [ ! -e "$fixture/lock-held" ]; do sleep 0.02; done
      (cd "$fixture/source" && XDG_RUNTIME_DIR="$fixture/runtime-a" \
        "$lifecycle_script" publisher) >"$fixture/publisher.out" 2>&1 &
      publisher_pid="$!"
      sleep 1
      kill -0 "$publisher_pid" 2>/dev/null || fail "$label pusher bypassed the repository lock"
      if git -C "$fixture/ledger.git" rev-parse --verify refs/dolt/data >/dev/null 2>&1; then
        fail "$label pusher published while the repository lock was held"
      fi
      touch "$fixture/release-lock"
      wait "$holder_pid"
      wait_for_ref_change "$fixture/ledger.git" "$before_ref" "$fixture/publisher.out"
      startup_ref="$(git -C "$fixture/ledger.git" rev-parse refs/dolt/data)"
      (cd "$fixture/source" && "$entry_dir/beads-status") >/dev/null
      stop_process "$publisher_pid"
      publisher_pid=""
      stop_process "$server_pid"
      server_pid=""

      # Consume the startup ref before any interval write so a later push
      # cannot mask an incomplete startup drain.
      git init -q -b main "$fixture/startup-source"
      git -C "$fixture/startup-source" commit -q --allow-empty -m seed
      (cd "$fixture/startup-source" && "$lifecycle_script" server) \
        >"$fixture/startup-server.out" 2>&1 &
      cold_server_pid="$!"
      for _attempt in $(seq 1 120); do
        if (cd "$fixture/startup-source" && "$entry_dir/beads-bootstrap") \
          >"$fixture/startup-bootstrap.out" 2>&1; then
          break
        fi
        sleep 0.1
      done
      grep -Fq "initialized module-owned Beads state" "$fixture/startup-bootstrap.out" \
        || fail "$label startup-ref consumer did not cold bootstrap"
      (cd "$fixture/startup-source" && "$entry_dir/bd" show "$actor_id" --json) >/dev/null
      (cd "$fixture/startup-source" && "$entry_dir/bd" show "$linked_id" --json) >/dev/null
      stop_process "$cold_server_pid"
      cold_server_pid=""

      (cd "$fixture/source" && "$lifecycle_script" server) \
        >"$fixture/server-before-interval.out" 2>&1 &
      server_pid="$!"
      for _attempt in $(seq 1 120); do
        if (cd "$fixture/source" && "$entry_dir/beads-bootstrap") \
          >"$fixture/bootstrap-before-interval.out" 2>&1; then
          break
        fi
        sleep 0.1
      done
      grep -Fq "verified existing module-owned Beads state" "$fixture/bootstrap-before-interval.out" \
        || fail "$label original state did not resume before interval publication"
      (cd "$fixture/source" && "$lifecycle_script" publisher) \
        >"$fixture/publisher-interval.out" 2>&1 &
      publisher_pid="$!"
      for _attempt in $(seq 1 120); do
        if grep -Fq "publication already drained" "$fixture/publisher-interval.out"; then
          break
        fi
        sleep 0.1
      done
      grep -Fq "publication already drained" "$fixture/publisher-interval.out" \
        || fail "$label interval publisher did not complete its startup no-op"
      interval_id="$(cd "$fixture/source" && "$entry_dir/bd" --actor human create "$label interval issue" --silent)"
      wait_for_ref_change "$fixture/ledger.git" "$startup_ref" "$fixture/publisher-interval.out"
      (cd "$fixture/source" && "$entry_dir/beads-status") >/dev/null
      stop_process "$publisher_pid"
      publisher_pid=""
      actual_ref="$(git -C "$fixture/ledger.git" rev-parse refs/dolt/data)"
      [ -n "$actual_ref" ] || fail "$label startup drain produced an empty ref"

      [ "$state_root" = "$(cd "$fixture/linked" && "$entry_dir/beads-status" | jq -er .stateRoot)" ] \
        || fail "$label linked worktree did not share lifecycle state"
      database="$(cd "$fixture/source" && "$entry_dir/beads-status" | jq -er .database)"
      db_path="$state_root/dolt-data/$database"
      (cd "$fixture/source" && "$entry_dir/beads-checkpoint") >/dev/null
      (cd "$fixture/source" && "$entry_dir/beads-diagnostics") >/dev/null

      # Stop the first state root and prove a fresh repository state restores
      # from the already-published refs/dolt/data branch through bd bootstrap.
      stop_process "$server_pid"
      server_pid=""
      git init -q -b main "$fixture/cold-source"
      git -C "$fixture/cold-source" commit -q --allow-empty -m seed
      git -C "$fixture/cold-source" status --short --untracked-files=all >"$fixture/cold.status.before"
      git -C "$fixture/cold-source" config --local --list | sort >"$fixture/cold.config.before"
      (cd "$fixture/cold-source" && "$lifecycle_script" server) >"$fixture/cold-server.out" 2>&1 &
      cold_server_pid="$!"
      for _attempt in $(seq 1 120); do
        if (cd "$fixture/cold-source" && "$entry_dir/beads-bootstrap") \
          >"$fixture/cold-bootstrap.out" 2>&1; then
          break
        fi
        sleep 0.1
      done
      if ! grep -Fq "initialized module-owned Beads state" "$fixture/cold-bootstrap.out"; then
        cat "$fixture/cold-bootstrap.out" >&2
        fail "$label cold existing-ledger bootstrap did not run"
      fi
      (cd "$fixture/cold-source" && "$entry_dir/bd" show "$actor_id" --json) >/dev/null
      (cd "$fixture/cold-source" && "$entry_dir/bd" show "$linked_id" --json) >/dev/null
      (cd "$fixture/cold-source" && "$entry_dir/bd" show "$interval_id" --json) >/dev/null
      (cd "$fixture/cold-source" && "$entry_dir/beads-checkpoint") >/dev/null
      git -C "$fixture/cold-source" status --short --untracked-files=all >"$fixture/cold.status.after"
      git -C "$fixture/cold-source" config --local --list | sort >"$fixture/cold.config.after"
      cmp "$fixture/cold.status.before" "$fixture/cold.status.after" \
        || fail "$label cold bootstrap changed the source checkout"
      cmp "$fixture/cold.config.before" "$fixture/cold.config.after" \
        || fail "$label cold bootstrap changed source local Git config"
      stop_process "$cold_server_pid"
      cold_server_pid=""

      (cd "$fixture/source" && "$lifecycle_script" server) >"$fixture/server-restart.out" 2>&1 &
      server_pid="$!"
      for _attempt in $(seq 1 120); do
        if (cd "$fixture/source" && "$entry_dir/beads-bootstrap") \
          >"$fixture/restart-bootstrap.out" 2>&1; then
          break
        fi
        sleep 0.1
      done
      grep -Fq "verified existing module-owned Beads state" "$fixture/restart-bootstrap.out" \
        || fail "$label original state did not re-enter after daemon restart"

      before_ref="$actual_ref"
      git -C "$fixture/ledger.git" update-ref refs/dolt/data refs/heads/main
      if (cd "$fixture/linked" && "$entry_dir/beads-publish") >"$fixture/divergence.out" 2>&1; then
        fail "$label pusher accepted divergent remote history"
      fi
      grep -Fq "diverged" "$fixture/divergence.out" \
        || fail "$label pusher rejected divergence for the wrong reason"
      git -C "$fixture/ledger.git" update-ref refs/dolt/data "$before_ref"

      before_ref="$(git -C "$fixture/ledger.git" rev-parse refs/dolt/data)"
      if [ "$origin_mode" = equal ]; then
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
        if (cd "$fixture/source" && "$entry_dir/bd" create "must not execute" --silent) \
          >"$fixture/dirty-client.out" 2>&1; then
          fail "$label guarded client accepted dirty incoming state"
        fi
        grep -Fq "dirty Dolt working set" "$fixture/dirty-client.out" \
          || fail "$label guarded client rejected dirty state for the wrong reason"
        if (cd "$fixture/linked" && "$entry_dir/beads-publish") \
          >"$fixture/dirty-pusher.out" 2>&1; then
          fail "$label pusher accepted dirty incoming state"
        fi
      else
        (
          cd "$db_path"
          DOLT_ROOT_PATH="$state_root/dolt-root" ${cfg.package.dolt}/bin/dolt \
            sql -r json -q "SET FOREIGN_KEY_CHECKS=0; INSERT INTO dependencies (id, issue_id, depends_on_issue_id, type, created_at, created_by) VALUES ('fixture-orphan-dependency', 'missing-owner', '$actor_id', 'blocks', NOW(), 'fixture'); SET FOREIGN_KEY_CHECKS=1; CALL DOLT_ADD('dependencies'); CALL DOLT_COMMIT('-m', 'fixture: committed orphan');" \
            >/dev/null
        )
        if (cd "$fixture/source" && "$entry_dir/bd" create "must not execute" --silent) \
          >"$fixture/invalid-client.out" 2>&1; then
          fail "$label guarded client accepted committed invalid state"
        fi
        grep -Eq "constraint violations|orphan dependencies" "$fixture/invalid-client.out" \
          || fail "$label guarded client rejected invalid state for the wrong reason"
        if (cd "$fixture/linked" && "$entry_dir/beads-publish") \
          >"$fixture/invalid-pusher.out" 2>&1; then
          fail "$label pusher accepted committed invalid state"
        fi
      fi
      [ "$(git -C "$fixture/ledger.git" rev-parse refs/dolt/data)" = "$before_ref" ] \
        || fail "$label invalid-state refusal changed the remote ref"

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
      server_pid=""
      trap - RETURN
      printf '%s=%s\n' "$label" passed
    }

    ${lib.optionalString (!(lib.any (path: lib.hasSuffix "/packages/beads/modules/devenv" (toString path)) self.devenvModules.nix-agentic-tools.imports)) ''
      fail "the exported devenv module does not include Beads"
    ''}
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
