{
  # cspell:ignore HASHOF versioncheck
  cfg,
  lib,
  pkgs,
}: let
  shellStrict = import ../../../config/shell-strict.nix;
  rawBd = lib.getExe cfg.package;
  dolt = lib.getExe cfg.package.dolt;
  ledgerUrl = lib.escapeShellArg cfg.ledgerUrl;
  issuePrefix = lib.escapeShellArg cfg.issuePrefix;
  database = lib.escapeShellArg "beads_${lib.replaceStrings ["-"] ["_"] cfg.issuePrefix}";
  expectedConfig = lib.concatStringsSep "\n" [
    "dolt:"
    "    auto-push: false"
    "export:"
    "    auto: false"
    "    git-add: false"
    "issue-prefix: ${cfg.issuePrefix}"
    "no-git-ops: true"
    "sync:"
    "    remote: ${builtins.toJSON cfg.ledgerUrl}"
  ];

  lifecycle = pkgs.writeShellApplication {
    name = "beads-lifecycle";
    inherit (shellStrict) bashOptions;
    extraShellCheckFlags = shellStrict.shellcheckFlags;
    text = ''
                ${shellStrict.shoptHeader}

                bd_bin=${lib.escapeShellArg rawBd}
                dolt_bin=${lib.escapeShellArg dolt}
                ledger_url=${ledgerUrl}
                issue_prefix=${issuePrefix}
                database=${database}
                server_port=${toString cfg.port}
                publish_interval=${toString cfg.publishIntervalSeconds}

                fail() {
                  printf 'beads lifecycle: %s\n' "$1" >&2
                  exit 1
                }

                atomic_line() {
                  local destination="$1" value="$2" temporary
                  temporary="$(${pkgs.coreutils}/bin/mktemp "$state_root/.checkpoint.XXXXXX")"
                  printf '%s\n' "$value" >"$temporary"
                  ${pkgs.coreutils}/bin/chmod 0600 "$temporary"
                  ${pkgs.coreutils}/bin/mv -f "$temporary" "$destination"
                }

                source_snapshot() {
                  local destination="$1"
                  {
                    ${pkgs.git}/bin/git -C "$source_root" rev-parse HEAD
                    ${pkgs.git}/bin/git -C "$source_root" status --short --untracked-files=all
                    ${pkgs.git}/bin/git -C "$source_root" config --local --list | ${pkgs.coreutils}/bin/sort
                  } >"$destination"
                }

                assert_source_unchanged() {
                  local before="$1" after
                  after="$(${pkgs.coreutils}/bin/mktemp "$state_root/.source-after.XXXXXX")"
                  source_snapshot "$after"
                  if ! ${pkgs.diffutils}/bin/cmp -s "$before" "$after"; then
                    ${pkgs.diffutils}/bin/diff -u "$before" "$after" >&2 || :
                    ${pkgs.coreutils}/bin/rm -f "$after"
                    fail "the source checkout or its local Git config changed"
                  fi
                  ${pkgs.coreutils}/bin/rm -f "$after"
                }

                prepare() {
                  local expected_config expected_owner new_state=0 state_base state_hash temporary

                  source_root="$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null)" \
                    || fail "run inside a Git worktree"
                  common_dir="$(${pkgs.git}/bin/git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
                    || fail "could not resolve the shared Git directory"
                  state_hash="$(printf '%s' "$common_dir" | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.gawk}/bin/awk '{print $1}')"
                  state_base="''${XDG_STATE_HOME:-''${HOME:?HOME is required}/.local/state}"
                  state_root="$state_base/nix-agentic-tools/beads/$state_hash"
                  beads_dir="$state_root/.beads"
                  dolt_data="$state_root/dolt-data"
                  dolt_root="$state_root/dolt-root"
                  neutral_cwd="$state_root/neutral"
                  repository_lock="$state_root/repository.lock"
                  server_lock="$state_root/server.lock"
                  expected_remote_file="$state_root/expected-remote.oid"
                  published_head_file="$state_root/published-head"
                  owner_file="$state_root/owner"

                  if [ ! -e "$owner_file" ]; then
                    if [ -e "$beads_dir/metadata.json" ] || [ -e "$expected_remote_file" ] || [ -e "$published_head_file" ]; then
                      fail "existing lifecycle state has no ownership marker"
                    fi
                    new_state=1
                  fi

                  ${pkgs.coreutils}/bin/install -d -m 0700 \
                    "$beads_dir" \
                    "$dolt_data" \
                    "$dolt_root" \
                    "$neutral_cwd" \
                    "$state_root/xdg-cache" \
                    "$state_root/xdg-config" \
                    "$state_root/xdg-data"

                  expected_owner="$common_dir
          $ledger_url
          $issue_prefix
          $database
          $server_port"
                  if [ -e "$owner_file" ]; then
                    if [ "$("${pkgs.coreutils}/bin/cat" "$owner_file")" != "$expected_owner" ]; then
                      fail "existing lifecycle state belongs to different repository settings"
                    fi
                  fi

      expected_config=${lib.escapeShellArg expectedConfig}
            if [ -e "$beads_dir/config.yaml" ]; then
              if [ "$("${pkgs.coreutils}/bin/cat" "$beads_dir/config.yaml")" != "$expected_config" ]; then
                temporary="$(${pkgs.coreutils}/bin/mktemp "$state_root/.expected-config.XXXXXX")"
                printf '%s\n' "$expected_config" >"$temporary"
                ${pkgs.diffutils}/bin/diff -u "$temporary" "$beads_dir/config.yaml" >&2 || :
                ${pkgs.coreutils}/bin/rm -f "$temporary"
                fail "module-owned Beads config differs from the declared lifecycle"
              fi
                  else
                    temporary="$(${pkgs.coreutils}/bin/mktemp "$beads_dir/.config.XXXXXX")"
                    printf '%s\n' "$expected_config" >"$temporary"
                    ${pkgs.coreutils}/bin/chmod 0600 "$temporary"
                    ${pkgs.coreutils}/bin/mv -f "$temporary" "$beads_dir/config.yaml"
                  fi
                  [ "$("${pkgs.coreutils}/bin/stat" -c %a "$beads_dir")" = 700 ] \
                    || fail "Beads state directory mode is not 0700"
                  [ "$("${pkgs.coreutils}/bin/stat" -c %a "$beads_dir/config.yaml")" = 600 ] \
                    || fail "Beads config mode is not 0600"

                  if [ "$new_state" -eq 1 ]; then
                    DOLT_ROOT_PATH="$dolt_root" "$dolt_bin" config --global --add metrics.disabled true
                    DOLT_ROOT_PATH="$dolt_root" "$dolt_bin" config --global --add user.email beads@localhost.invalid
                    DOLT_ROOT_PATH="$dolt_root" "$dolt_bin" config --global --add user.name "Beads lifecycle"
                    DOLT_ROOT_PATH="$dolt_root" "$dolt_bin" config --global --add versioncheck.disabled true
                    temporary="$(${pkgs.coreutils}/bin/mktemp "$state_root/.owner.XXXXXX")"
                    printf '%s\n' "$expected_owner" >"$temporary"
                    ${pkgs.coreutils}/bin/chmod 0600 "$temporary"
                    ${pkgs.coreutils}/bin/mv -f "$temporary" "$owner_file"
                  fi

                  [ "$(DOLT_ROOT_PATH="$dolt_root" "$dolt_bin" config --global --get metrics.disabled)" = true ] \
                    || fail "contained Dolt metrics must remain disabled"
                }

          run_bd_raw() {
            (
              cd "$neutral_cwd"
              ${pkgs.coreutils}/bin/env \
                BD_DOLT_AUTO_PUSH=false \
                BEADS_DIR="$beads_dir" \
                BEADS_DOLT_SERVER_DATABASE="$database" \
                BEADS_DOLT_SERVER_HOST=127.0.0.1 \
                BEADS_DOLT_SERVER_MODE=1 \
                BEADS_DOLT_SERVER_PORT="$server_port" \
                GIT_TERMINAL_PROMPT=0 \
                XDG_CACHE_HOME="$state_root/xdg-cache" \
                XDG_CONFIG_HOME="$state_root/xdg-config" \
                XDG_DATA_HOME="$state_root/xdg-data" \
                "$bd_bin" "$@"
                  )
                }

                run_dolt() {
                  local cwd="$1"
            shift
            (
              cd "$cwd"
              ${pkgs.coreutils}/bin/env \
                DOLT_DISABLE_EVENT_FLUSH=1 \
                DOLT_ROOT_PATH="$dolt_root" \
                GIT_TERMINAL_PROMPT=0 \
                "$dolt_bin" "$@"
                  )
                }

      server_ready() {
        ${pkgs.coreutils}/bin/timeout 1 \
          ${pkgs.bash}/bin/bash -c 'exec 3<>"/dev/tcp/$1/$2"' -- \
          127.0.0.1 "$server_port" >/dev/null 2>&1
                }

                require_server() {
                  server_ready || fail "the module-owned Dolt daemon is not ready on 127.0.0.1:$server_port"
                }

                database_sql() {
                  run_dolt "$dolt_data/$database" sql -r json -q "$1"
                }

                row_count() {
                  database_sql "$1" | ${pkgs.jq}/bin/jq -er '.rows[0].n'
                }

                head_hash() {
                  database_sql "SELECT HASHOF('HEAD') AS hash" | ${pkgs.jq}/bin/jq -er '.rows[0].hash'
                }

                status_count() {
                  row_count 'SELECT COUNT(*) AS n FROM dolt_status'
                }

                remote_ref() {
                  local output rc
                  if output="$(${pkgs.git}/bin/git ls-remote --exit-code "$ledger_url" refs/dolt/data 2>/dev/null)"; then
                    [ "$(printf '%s\n' "$output" | ${pkgs.coreutils}/bin/wc -l)" -eq 1 ] \
                      || fail "ledger remote returned more than one refs/dolt/data"
                    printf '%s\n' "$output" | ${pkgs.gawk}/bin/awk '{print $1}'
                    return
                  else
                    rc="$?"
                  fi
                  if [ "$rc" -eq 2 ]; then
                    printf '%s\n' absent
                    return
                  fi
                  fail "could not read refs/dolt/data from the declared ledger URL"
                }

                assert_clean_valid() {
            local actual actual_remote expected_remote metadata_database server_shape
                  [ -d "$dolt_data/$database" ] || fail "the declared Dolt database is absent"
                  [ -f "$beads_dir/metadata.json" ] || fail "Beads metadata is absent"
                  metadata_database="$(${pkgs.jq}/bin/jq -er '.dolt_database | select(type == "string" and length > 0)' "$beads_dir/metadata.json")" \
                    || fail "Beads metadata has no Dolt database"
                  [ "$metadata_database" = "$database" ] || fail "Beads metadata selects a different Dolt database"

                  actual="$(status_count)" || fail "could not inspect the Dolt working set"
                  [ "$actual" -eq 0 ] || fail "incoming state left a dirty Dolt working set"
                  actual="$(row_count 'SELECT COUNT(*) AS n FROM dolt_constraint_violations')" \
                    || fail "could not inspect constraint violations"
                  [ "$actual" -eq 0 ] || fail "ledger exposes constraint violations"
                  actual="$(row_count 'SELECT COUNT(*) AS n FROM events e LEFT JOIN issues i ON i.id = e.issue_id WHERE i.id IS NULL')" \
                    || fail "could not inspect event orphans"
                  [ "$actual" -eq 0 ] || fail "ledger exposes orphan events"
                  actual="$(row_count 'SELECT COUNT(*) AS n FROM dependencies d LEFT JOIN issues owner ON owner.id = d.issue_id LEFT JOIN issues target ON target.id = d.depends_on_issue_id WHERE owner.id IS NULL OR (d.depends_on_issue_id IS NOT NULL AND target.id IS NULL)')" \
                    || fail "could not inspect dependency orphans"
                  [ "$actual" -eq 0 ] || fail "ledger exposes orphan dependencies"
                  actual="$(run_bd_raw where --json | ${pkgs.jq}/bin/jq -er .path)" \
                    || fail "could not resolve the active Beads workspace"
                  [ "$actual" = "$beads_dir" ] || fail "Beads resolved outside module-owned state"
                  actual="$(run_bd_raw config show --json | ${pkgs.jq}/bin/jq -r '.[] | select(.key == "sync.remote") | .value')"
                  [ "$actual" = "$ledger_url" ] || fail "Beads sync.remote differs from the declared URL"
                  expected_remote="git+$ledger_url"
                  actual_remote="$(run_bd_raw dolt remote list --json | ${pkgs.jq}/bin/jq -c '[.[] | {name, url, sql_url, status}]')" \
                    || fail "could not inspect the Beads Dolt remote"
            [ "$actual_remote" = "[{\"name\":\"origin\",\"url\":\"$expected_remote\",\"sql_url\":\"$expected_remote\",\"status\":\"ok\"}]" ] \
              || fail "Beads Dolt remote differs from the declared URL"
            server_shape="$(run_bd_raw dolt show --json)" \
              || fail "could not inspect the external Dolt server"
            ${pkgs.jq}/bin/jq -e \
              --arg database "$database" \
              --argjson port "$server_port" \
              '.connection_ok == true and .database == $database and .host == "127.0.0.1" and .port == $port' \
              <<<"$server_shape" >/dev/null \
              || fail "Beads is not connected to the declared external Dolt server"
                }

      commit_checkpoint() {
        local after before dirty
        before="$(head_hash)"
        dirty="$(status_count)"
        # Always cross Beads' commit-if-needed barrier. In external-server
        # mode an ordinary command may have returned before a separately
        # pooled StageAndCommit completes, even when a live status read looks
        # clean. This normalization call is therefore load-bearing on reads as
        # well as writes; on an already-clean HEAD it is a no-op.
        run_bd_raw dolt commit -m "lifecycle: repository checkpoint" >/dev/null
        if [ "$(status_count)" -ne 0 ]; then
          run_dolt "$dolt_data/$database" sql -r json \
            -q "CALL DOLT_ADD('config'); CALL DOLT_COMMIT('-m', 'lifecycle: activation config');" >/dev/null
        fi
        if [ "$dirty" -ne 0 ]; then
          after="$(head_hash)"
          [ "$after" != "$before" ] || fail "dirty mutation did not advance Dolt history"
        fi
                  assert_clean_valid
                }

                bootstrap_locked() {
                  local before remote
                  before="$(${pkgs.coreutils}/bin/mktemp "$state_root/.source-before.XXXXXX")"
                  source_snapshot "$before"
                  require_server

                  if [ -d "$dolt_data/$database" ]; then
                    [ -f "$expected_remote_file" ] || fail "existing database has no remote checkpoint"
                    [ -f "$published_head_file" ] || fail "existing database has no publication checkpoint"
                    assert_clean_valid
                    remote="$(remote_ref)"
                    [ "$remote" = "$("${pkgs.coreutils}/bin/cat" "$expected_remote_file")" ] \
                      || fail "ledger remote diverged from the last observed checkpoint"
                    assert_source_unchanged "$before"
                    ${pkgs.coreutils}/bin/rm -f "$before"
                    printf '%s\n' "verified existing module-owned Beads state"
                    return
                  fi

                  remote="$(remote_ref)"
                  if [ "$remote" = absent ]; then
                    run_bd_raw init \
                      --database "$database" \
                      --external \
                      --init-if-missing \
                      --non-interactive \
                      --prefix "$issue_prefix" \
                      --remote "$ledger_url" \
                      --server \
                      --server-host 127.0.0.1 \
                      --server-port "$server_port" \
                      --skip-agents \
                      --skip-hooks
                    commit_checkpoint
                    atomic_line "$published_head_file" absent
                  else
                    run_bd_raw bootstrap --non-interactive --json
                    assert_clean_valid
                    atomic_line "$published_head_file" "$(head_hash)"
                  fi
                  atomic_line "$expected_remote_file" "$remote"
                  assert_source_unchanged "$before"
                  ${pkgs.coreutils}/bin/rm -f "$before"
                  printf '%s\n' "initialized module-owned Beads state"
                }

                acquire_repository_lock() {
                  exec {repository_lock_fd}>"$repository_lock" \
                    || fail "could not open the repository lock"
                  ${pkgs.util-linux}/bin/flock "$repository_lock_fd" \
                    || fail "could not acquire the repository lock"
                }

                release_repository_lock() {
                  ${pkgs.util-linux}/bin/flock -u "$repository_lock_fd" \
                    || fail "could not release the repository lock"
                  exec {repository_lock_fd}>&- \
                    || fail "could not close the repository lock"
                }

                bootstrap() {
                  prepare
                  acquire_repository_lock
                  bootstrap_locked
                  release_repository_lock
                }

                checkpoint() {
                  prepare
                  acquire_repository_lock
                  bootstrap_locked >/dev/null
                  assert_clean_valid
                  printf 'clean checkpoint %s\n' "$(head_hash)"
                  release_repository_lock
                }

                command_name() {
                  local argument
                  while [ "$#" -gt 0 ]; do
                    argument="$1"
                    case "$argument" in
                      --actor)
                        [ "$#" -ge 2 ] || fail "missing value for $argument"
                        shift 2
                        ;;
                      --actor=*)
                        shift
                        ;;
                      --db | --directory | --dolt-auto-commit | -C)
                        fail "$argument is outside the guarded repository workspace"
                        ;;
                      --db=* | --directory=* | --dolt-auto-commit=* | --global | --ignore-schema-skew)
                        fail "$argument is outside the guarded repository workspace"
                        ;;
                      --*)
                        shift
                        ;;
                      -*)
                        shift
                        ;;
                      *)
                        printf '%s\n' "$argument"
                        return
                        ;;
                    esac
                  done
                  printf '%s\n' ""
                }

                guarded_bd() {
                  local before command rc
                  command="$(command_name "$@")"
                  case "$command" in
                    "" | completion | help | human | init-safety | metrics | quickstart | version)
                      exec "$bd_bin" "$@"
                      ;;
              admin | ado | bootstrap | branch | compact | config | doctor | dolt | federation | flatten | gc | github | gitlab | hooks | init | jira | linear | mail | migrate | notion | onboard | prune | purge | recompute-blocked | repo | restore | rules | setup | ship | sql | sync | upgrade | vc | worktree)
                fail "bd $command is outside the guarded repository mutation surface"
                ;;
              *) : ;;
                  esac

                  prepare
                  acquire_repository_lock
                  bootstrap_locked >/dev/null
                  assert_clean_valid
                  before="$(head_hash)"
                  if run_bd_raw --dolt-auto-commit off "$@"; then
                    rc=0
                  else
                    rc="$?"
                  fi
                  if [ "$rc" -ne 0 ]; then
                    [ "$(status_count)" -eq 0 ] \
                      || fail "failed bd command left dirty state; refusing further mutation"
                    [ "$(head_hash)" = "$before" ] \
                      || fail "failed bd command advanced history"
                    release_repository_lock
                    return "$rc"
                  fi
                  commit_checkpoint
                  release_repository_lock
                }

                publish_once() {
                  local actual after before local_head published source_before
                  prepare
                  acquire_repository_lock
                  bootstrap_locked >/dev/null
                  assert_clean_valid
                  source_before="$(${pkgs.coreutils}/bin/mktemp "$state_root/.source-before.XXXXXX")"
                  source_snapshot "$source_before"
                  before="$("${pkgs.coreutils}/bin/cat" "$expected_remote_file")"
                  published="$("${pkgs.coreutils}/bin/cat" "$published_head_file")"
                  actual="$(remote_ref)"
                  [ "$actual" = "$before" ] || fail "ledger remote diverged; refusing publication"
                  local_head="$(head_hash)"
                  if [ "$local_head" = "$published" ]; then
                    assert_source_unchanged "$source_before"
                    ${pkgs.coreutils}/bin/rm -f "$source_before"
                    release_repository_lock
                    printf '%s\n' "publication already drained"
                    return
                  fi

                  run_dolt "$dolt_data/$database" push --set-upstream origin main
                  after="$(remote_ref)"
                  [ "$after" != absent ] || fail "publication did not create refs/dolt/data"
                  [ "$after" != "$before" ] || fail "publication did not advance refs/dolt/data"
                  assert_clean_valid
                  atomic_line "$expected_remote_file" "$after"
                  atomic_line "$published_head_file" "$local_head"
                  assert_source_unchanged "$source_before"
                  ${pkgs.coreutils}/bin/rm -f "$source_before"
                  release_repository_lock
                  printf 'published refs/dolt/data %s\n' "$after"
                }

                status() {
                  local actual expected initialized=false local_head=null published=null
                  prepare
                  acquire_repository_lock
                  if [ -d "$dolt_data/$database" ]; then
                    require_server
                    assert_clean_valid
                    initialized=true
                    actual="$(remote_ref)"
                    expected="$("${pkgs.coreutils}/bin/cat" "$expected_remote_file")"
                    local_head="$(head_hash)"
                    published="$("${pkgs.coreutils}/bin/cat" "$published_head_file")"
                  else
                    actual="$(remote_ref)"
                    expected=null
                  fi
                  ${pkgs.jq}/bin/jq -n \
                    --arg actualRemote "$actual" \
                    --arg database "$database" \
                    --arg expectedRemote "$expected" \
                    --argjson initialized "$initialized" \
                    --arg ledgerUrl "$ledger_url" \
                    --arg localHead "$local_head" \
                    --arg publishedHead "$published" \
                    --arg stateRoot "$state_root" \
                    '{actualRemote: $actualRemote, database: $database, expectedRemote: $expectedRemote, initialized: $initialized, ledgerUrl: $ledgerUrl, localHead: $localHead, publishedHead: $publishedHead, stateRoot: $stateRoot}'
                  release_repository_lock
                }

                diagnostics() {
                  prepare
                  printf 'bd: '
                  "$bd_bin" --version
                  printf 'dolt: '
                  DOLT_ROOT_PATH="$dolt_root" "$dolt_bin" version | ${pkgs.coreutils}/bin/head -n 1
                  status
                }

                publisher() {
                  while ! server_ready; do
                    ${pkgs.coreutils}/bin/sleep 1
                  done
                  publish_once
                  while true; do
                    ${pkgs.coreutils}/bin/sleep "$publish_interval"
                    publish_once
                  done
                }

                server() {
                  prepare
                  exec {server_lock_fd}>"$server_lock" || fail "could not open the server lock"
                  if ! ${pkgs.util-linux}/bin/flock -n "$server_lock_fd"; then
                    fail "the shared repository Dolt daemon is already owned"
                  fi
                  if server_ready; then
                    fail "a Dolt daemon is already serving the lifecycle state"
            fi
            cd "$dolt_data"
            exec ${pkgs.coreutils}/bin/env \
              DOLT_DISABLE_EVENT_FLUSH=1 \
              DOLT_ROOT_PATH="$dolt_root" \
              "$dolt_bin" sql-server --host 127.0.0.1 --port "$server_port"
                }

                subcommand="''${1:-}"
                [ "$#" -gt 0 ] && shift
                case "$subcommand" in
                  bd) guarded_bd "$@" ;;
                  bootstrap) bootstrap "$@" ;;
                  checkpoint) checkpoint "$@" ;;
                  diagnostics) diagnostics "$@" ;;
                  prepare) prepare "$@" ;;
                  publish-once) publish_once "$@" ;;
                  publisher) publisher "$@" ;;
                  server) server "$@" ;;
                  status) status "$@" ;;
                  *) fail "expected bd, bootstrap, checkpoint, diagnostics, prepare, publish-once, publisher, server, or status" ;;
                esac
    '';
  };

  mkEntry = name: subcommand:
    pkgs.writeShellApplication {
      inherit name;
      inherit (shellStrict) bashOptions;
      extraShellCheckFlags = shellStrict.shellcheckFlags;
      text = ''
        ${shellStrict.shoptHeader}
        exec ${lib.getExe' lifecycle "beads-lifecycle"} ${subcommand} "$@"
      '';
    };

  entries = [
    (mkEntry "bd" "bd")
    (mkEntry "beads-bootstrap" "bootstrap")
    (mkEntry "beads-checkpoint" "checkpoint")
    (mkEntry "beads-diagnostics" "diagnostics")
    (mkEntry "beads-publish" "publish-once")
    (mkEntry "beads-status" "status")
  ];

  package = pkgs.symlinkJoin {
    name = "beads-lifecycle-tools";
    paths = entries;
    passthru = {
      inherit lifecycle;
      dolt = cfg.package.dolt;
      unwrapped = cfg.package;
    };
    meta.mainProgram = "bd";
  };
in {
  inherit lifecycle package;
}
