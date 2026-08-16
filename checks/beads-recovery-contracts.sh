#!/usr/bin/env bash
# cspell:words HASHOF NOSYSTEM versioncheck
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

if (($# != 2)); then
  printf 'usage: %s /path/to/bd /path/to/dolt\n' "$0" >&2
  exit 2
fi

bd_bin="$1"
dolt_bin="$2"
probe_root="$(mktemp -d "${TMPDIR:-/tmp}/beads-recovery-contracts.XXXXXXXX")"
probe_marker="$probe_root/.beads-recovery-contracts"
active_cwd=""
active_data=""
active_database=""
active_dolt_root=""
active_home=""
active_state=""
ledger_path=""
linked_expected_head=""
repository_lock=""
scenario_root=""
server_pid=""
server_port=""
source_expected_config=""
source_expected_head=""
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0
export HOME="$probe_root/git-home"
export XDG_CONFIG_HOME="$probe_root/git-home/.config"

install -m 0600 /dev/null "$probe_marker"

fail() {
  printf 'beads-recovery-contracts: %s\n' "$1" >&2
  exit 1
}

port_is_open() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

stop_server() {
  if [[ -n $server_pid ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill -TERM "$server_pid" 2>/dev/null || :
    for _ in $(seq 1 100); do
      if ! kill -0 "$server_pid" 2>/dev/null; then
        break
      fi
      sleep 0.05
    done
    if kill -0 "$server_pid" 2>/dev/null; then
      kill -KILL "$server_pid" 2>/dev/null || :
    fi
    wait "$server_pid" 2>/dev/null || :
  fi
  server_pid=""
}

cleanup() {
  stop_server
  case "$probe_root" in
  "${TMPDIR:-/tmp}"/beads-recovery-contracts.*)
    if [[ -f $probe_marker ]]; then
      rm -rf -- "$probe_root"
    else
      printf 'refusing to clean unmarked probe root: %s\n' "$probe_root" >&2
    fi
    ;;
  *)
    printf 'refusing to clean unexpected probe root: %s\n' "$probe_root" >&2
    ;;
  esac
}
trap cleanup EXIT

run_dolt_in() {
  local cwd="$1"
  shift
  (
    cd "$cwd"
    env -i \
      HOME="$active_home" \
      DOLT_DISABLE_EVENT_FLUSH=1 \
      DOLT_ROOT_PATH="$active_dolt_root" \
      GIT_CONFIG_GLOBAL=/dev/null \
      GIT_CONFIG_NOSYSTEM=1 \
      GIT_TERMINAL_PROMPT=0 \
      PATH="$PATH" \
      timeout --kill-after=5 --signal=TERM 120 "$dolt_bin" "$@"
  )
}

server_is_ours() {
  run_dolt_in "$active_data" sql -r json -q 'SELECT 1 AS ready' 2>/dev/null |
    jq -e '.rows == [{"ready": "1"}]' >/dev/null
}

start_server() {
  local candidate info phase_slot="$1"
  info="$active_data/.dolt/sql-server.info"
  for candidate in $(seq "$((43000 + phase_slot * 500 + ($$ % 250)))" \
    "$((43249 + phase_slot * 500))"); do
    if port_is_open "$candidate"; then
      continue
    fi
    if [[ -e $info ]]; then
      rm -f -- "$info"
    fi
    server_port="$candidate"
    (
      cd "$active_data"
      env -i \
        HOME="$active_home" \
        DOLT_DISABLE_EVENT_FLUSH=1 \
        DOLT_ROOT_PATH="$active_dolt_root" \
        GIT_CONFIG_GLOBAL=/dev/null \
        GIT_CONFIG_NOSYSTEM=1 \
        GIT_TERMINAL_PROMPT=0 \
        PATH="$PATH" \
        "$dolt_bin" sql-server \
        --host 127.0.0.1 \
        --loglevel debug \
        --port "$server_port"
    ) >"$active_data/server.log" 2>&1 &
    server_pid="$!"
    for _ in $(seq 1 200); do
      if kill -0 "$server_pid" 2>/dev/null &&
        [[ -f $info ]] &&
        [[ $(<"$info") == "$server_pid:$server_port:"* ]] &&
        port_is_open "$server_port" &&
        server_is_ours; then
        return
      fi
      if ! kill -0 "$server_pid" 2>/dev/null; then
        break
      fi
      sleep 0.05
    done
    stop_server
  done
  fail "could not start isolated Dolt server for $active_database"
}

activate_phase() {
  local name="$1" phase_slot="$2" include_prefix="$3"
  stop_server
  active_cwd="$scenario_root/$name/cwd"
  active_data="$scenario_root/$name/dolt-data"
  active_database="${name}_$$_${RANDOM}_$(date +%s%N)"
  active_dolt_root="$scenario_root/$name/dolt-root"
  active_home="$scenario_root/$name/home"
  active_state="$scenario_root/$name/state/.beads"
  install -d -m 0700 \
    "$active_cwd" \
    "$active_data" \
    "$active_dolt_root" \
    "$active_home/.cache" \
    "$active_home/.config/beads" \
    "$active_home/.local/share" \
    "$active_state"
  if [[ $include_prefix == true ]]; then
    install -m 0600 /dev/stdin "$active_state/config.yaml" <<EOF
dolt:
  auto-push: false
export:
  auto: false
  git-add: false
issue-prefix: recovery
no-git-ops: true
sync:
  remote: file://$ledger_path
EOF
  else
    install -m 0600 /dev/stdin "$active_state/config.yaml" <<EOF
dolt:
  auto-push: false
export:
  auto: false
  git-add: false
no-git-ops: true
sync:
  remote: file://$ledger_path
EOF
  fi
  run_dolt_in "$active_data" config --global --add metrics.disabled true >/dev/null
  run_dolt_in "$active_data" config --global --add user.email probe@example.invalid >/dev/null
  run_dolt_in "$active_data" config --global --add user.name Probe >/dev/null
  run_dolt_in "$active_data" config --global --add versioncheck.disabled true >/dev/null
  start_server "$phase_slot"
  install -m 0600 /dev/stdin "$active_home/.config/beads/credentials" <<EOF
[127.0.0.1:$server_port]
password =
EOF
}

run_bd_as() {
  local cwd="$1" actor="$2"
  local -a actor_env=()
  shift 2
  if [[ -n $actor ]]; then
    actor_env=("BEADS_ACTOR=$actor")
  fi
  (
    cd "$cwd"
    env -i \
      HOME="$active_home" \
      XDG_CACHE_HOME="$active_home/.cache" \
      XDG_CONFIG_HOME="$active_home/.config" \
      XDG_DATA_HOME="$active_home/.local/share" \
      BEADS_DIR="$active_state" \
      BEADS_DOLT_SERVER_DATABASE="$active_database" \
      BEADS_DOLT_SERVER_HOST=127.0.0.1 \
      BEADS_DOLT_SERVER_MODE=1 \
      BEADS_DOLT_SERVER_PORT="$server_port" \
      BD_DOLT_AUTO_PUSH=false \
      GIT_CONFIG_GLOBAL=/dev/null \
      GIT_CONFIG_NOSYSTEM=1 \
      GIT_TERMINAL_PROMPT=0 \
      "${actor_env[@]}" \
      PATH="$PATH" \
      timeout --kill-after=5 --signal=TERM 120 "$bd_bin" "$@"
  )
}

run_bd() {
  run_bd_as "$active_cwd" "" "$@"
}

database_sql() {
  run_dolt_in "$active_data/$active_database" sql -r json -q "$1"
}

canonical_rows() {
  jq -S '
    def canonical_value:
      if type == "string" and test("^\\s*[\\[{]") then
        (try fromjson catch .) | canonical_value
      elif type == "array" then
        map(canonical_value)
      elif type == "object" then
        with_entries(.value |= canonical_value)
      elif type == "number" or type == "boolean" then
        tostring
      else
        .
      end;
    .rows | canonical_value
  '
}

head_hash() {
  database_sql "SELECT HASHOF('HEAD') AS hash" | jq -er '.rows[0].hash'
}

row_count() {
  database_sql "$1" | jq -er '.rows[0].n'
}

constraint_count() {
  row_count 'SELECT COUNT(*) AS n FROM dolt_constraint_violations'
}

dependency_orphan_count() {
  row_count 'SELECT COUNT(*) AS n FROM dependencies d LEFT JOIN issues owner ON owner.id = d.issue_id LEFT JOIN issues target ON target.id = d.depends_on_issue_id WHERE owner.id IS NULL OR (d.depends_on_issue_id IS NOT NULL AND target.id IS NULL)'
}

event_orphan_count() {
  row_count 'SELECT COUNT(*) AS n FROM events e LEFT JOIN issues i ON i.id = e.issue_id WHERE i.id IS NULL'
}

status_count() {
  row_count 'SELECT COUNT(*) AS n FROM dolt_status'
}

remote_ref() {
  git -C "$ledger_path" rev-parse --verify refs/dolt/data 2>/dev/null ||
    printf '%s\n' absent
}

assert_source_git_unchanged() {
  [[ $(git -C "$scenario_root/source" rev-parse HEAD) == "$source_expected_head" ]] ||
    fail "source HEAD changed during $1"
  [[ $(git -C "$scenario_root/linked" rev-parse HEAD) == "$linked_expected_head" ]] ||
    fail "linked HEAD changed during $1"
  if [[ -n $(git -C "$scenario_root/source" status --short --untracked-files=all) ]]; then
    git -C "$scenario_root/source" status --short --untracked-files=all >&2
    fail "source worktree changed during $1"
  fi
  if [[ -n $(git -C "$scenario_root/linked" status --short --untracked-files=all) ]]; then
    git -C "$scenario_root/linked" status --short --untracked-files=all >&2
    fail "linked worktree changed during $1"
  fi
  git -C "$scenario_root/source" config --local --list | sort \
    >"$scenario_root/source-config.actual"
  cmp "$source_expected_config" "$scenario_root/source-config.actual" ||
    fail "source Git config changed during $1"
}

assert_clean_valid() {
  local label="$1" actual_count actual_path actual_remote expected_remote
  if ! actual_count="$(status_count)"; then
    fail "$label could not inspect the Dolt working set"
  fi
  if [[ $actual_count != 0 ]]; then
    run_dolt_in "$active_data/$active_database" sql -r tabular \
      -q 'SELECT * FROM dolt_status' >&2
    fail "$label left a dirty Dolt working set"
  fi
  if ! actual_count="$(constraint_count)"; then
    fail "$label could not inspect constraint violations"
  fi
  [[ $actual_count == 0 ]] || fail "$label exposed constraint violations"
  if ! actual_count="$(event_orphan_count)"; then
    fail "$label could not inspect orphan events"
  fi
  [[ $actual_count == 0 ]] || fail "$label exposed orphan events"
  if ! actual_count="$(dependency_orphan_count)"; then
    fail "$label could not inspect orphan dependencies"
  fi
  [[ $actual_count == 0 ]] || fail "$label exposed orphan dependencies"
  if ! actual_path="$(run_bd where --json | jq -er .path)"; then
    fail "$label could not resolve the Beads state"
  fi
  [[ $actual_path == "$active_state" ]] ||
    fail "$label resolved the wrong Beads state"
  expected_remote="git+file://$ledger_path"
  if ! actual_remote="$(run_bd dolt remote list --json |
    jq -c '[.[] | {name, url, sql_url, status}]')"; then
    fail "$label could not inspect the configured ledger remote"
  fi
  [[ $actual_remote == "[{\"name\":\"origin\",\"url\":\"$expected_remote\",\"sql_url\":\"$expected_remote\",\"status\":\"ok\"}]" ]] ||
    fail "$label changed the configured ledger remote"
  assert_source_git_unchanged "$label"
}

commit_activation_config() {
  local label="$1"
  if [[ $(status_count) == 0 ]]; then
    return
  fi
  run_dolt_in "$active_data/$active_database" sql -r json \
    -q "CALL DOLT_ADD('config'); CALL DOLT_COMMIT('-m', 'contract: $label config');" \
    >"$scenario_root/$label-config-commit.out"
}

locked_init() {
  local label="$1" lock_fd
  shift
  exec {lock_fd}>"$repository_lock"
  flock "$lock_fd"
  if ! run_bd "$@" >"$scenario_root/$label.out" 2>&1; then
    sed 's/^/init: /' "$scenario_root/$label.out" >&2
    fail "$label failed"
  fi
  commit_activation_config "$label"
  assert_clean_valid "$label"
  flock -u "$lock_fd"
  exec {lock_fd}>&-
}

locked_bootstrap() {
  local label="$1" lock_fd
  [[ ! -e $active_data/$active_database ]] ||
    fail "$label did not start from an absent database"
  exec {lock_fd}>"$repository_lock"
  flock "$lock_fd"
  if ! run_bd bootstrap --non-interactive --json >"$scenario_root/$label.out" 2>&1; then
    sed 's/^/bootstrap: /' "$scenario_root/$label.out" >&2
    fail "$label failed"
  fi
  assert_clean_valid "$label"
  flock -u "$lock_fd"
  exec {lock_fd}>&-
}

locked_mutation() {
  local label="$1" cwd="$2" actor="$3" before_head after_head lock_fd output
  shift 3
  exec {lock_fd}>"$repository_lock"
  flock "$lock_fd"
  assert_clean_valid "$label incoming state"
  before_head="$(head_hash)"
  if ! output="$(run_bd_as "$cwd" "$actor" "$@" \
    2>"$scenario_root/$label-mutation.err")"; then
    sed 's/^/mutation: /' "$scenario_root/$label-mutation.err" >&2
    printf 'mutation: %s\n' "$output" >&2
    fail "$label mutation failed"
  fi
  if ! run_bd_as "$active_cwd" "$actor" dolt commit -m "contract: $label" \
    >"$scenario_root/$label-commit.out" 2>&1; then
    sed 's/^/commit: /' "$scenario_root/$label-commit.out" >&2
    fail "$label checkpoint failed"
  fi
  commit_activation_config "$label"
  after_head="$(head_hash)"
  [[ $after_head != "$before_head" ]] || fail "$label did not advance Dolt history"
  assert_clean_valid "$label"
  flock -u "$lock_fd"
  exec {lock_fd}>&-
  printf '%s\n' "$output"
}

dirty_preflight_control() {
  local issue_id="$1" before_head lock_fd marker_title
  marker_title="dirty preflight marker must not execute"
  before_head="$(head_hash)"
  run_dolt_in "$active_data/$active_database" log --oneline \
    >"$scenario_root/dirty-preflight-history.before"

  exec {lock_fd}>"$repository_lock"
  flock "$lock_fd"
  run_dolt_in "$active_data/$active_database" sql -r json \
    -q "UPDATE issues SET notes = 'controlled dirty-state residue' WHERE id = '$issue_id';" \
    >"$scenario_root/dirty-preflight-residue.out"
  [[ $(status_count) != 0 ]] || fail "dirty preflight control did not create residue"
  flock -u "$lock_fd"
  exec {lock_fd}>&-

  if (
    trap - EXIT
    locked_mutation dirty-preflight-marker "$active_cwd" codex \
      create "$marker_title" --silent
  ) >"$scenario_root/dirty-preflight-refusal.out" 2>&1; then
    fail "locked mutation accepted dirty incoming state"
  fi
  grep -Fq 'incoming state left a dirty Dolt working set' \
    "$scenario_root/dirty-preflight-refusal.out" ||
    fail "locked mutation rejected dirty state for the wrong reason"
  [[ $(head_hash) == "$before_head" ]] ||
    fail "dirty preflight refusal changed HEAD"
  run_dolt_in "$active_data/$active_database" log --oneline \
    >"$scenario_root/dirty-preflight-history.after"
  cmp "$scenario_root/dirty-preflight-history.before" \
    "$scenario_root/dirty-preflight-history.after" ||
    fail "dirty preflight refusal changed history"
  [[ $(row_count "SELECT COUNT(*) AS n FROM issues WHERE title = '$marker_title'") == 0 ]] ||
    fail "dirty preflight marker mutation executed"
  printf 'dirty_preflight=refused_without_mutation\n'
}

pusher_preflight() {
  local expected_remote="$1" actual_remote expected_url
  [[ $(status_count) == 0 ]] || return 1
  [[ $(constraint_count) == 0 ]] || return 1
  [[ $(event_orphan_count) == 0 ]] || return 1
  [[ $(dependency_orphan_count) == 0 ]] || return 1
  actual_remote="$(remote_ref)"
  [[ $actual_remote == "$expected_remote" ]] || return 1
  expected_url="git+file://$ledger_path"
  run_bd dolt remote list --json |
    jq -e --arg url "$expected_url" \
      'length == 1 and .[0].name == "origin" and .[0].url == $url and .[0].sql_url == $url and .[0].status == "ok"' \
      >/dev/null || return 1
  assert_source_git_unchanged "pusher preflight"
}

publish_locked() {
  local expected_remote="$1" label="$2" lock_fd published_remote
  exec {lock_fd}>"$repository_lock"
  flock "$lock_fd"
  if ! pusher_preflight "$expected_remote"; then
    flock -u "$lock_fd"
    exec {lock_fd}>&-
    return 1
  fi
  run_dolt_in "$active_data/$active_database" push --set-upstream origin main \
    >"$scenario_root/$label.out" 2>&1
  published_remote="$(remote_ref)"
  [[ $published_remote != absent ]] || fail "$label did not create the remote ledger ref"
  [[ $published_remote != "$expected_remote" ]] || fail "$label did not advance the remote ref"
  assert_clean_valid "$label"
  flock -u "$lock_fd"
  exec {lock_fd}>&-
  printf '%s\n' "$published_remote"
}

snapshot_phase() {
  local destination="$1"
  head_hash >"$destination.head"
  run_dolt_in "$active_data/$active_database" ls HEAD | sort >"$destination.tables"
  database_sql 'SELECT * FROM issues ORDER BY id' | canonical_rows >"$destination.issues"
  run_bd list --all --limit 0 --json | jq -S 'sort_by(.id)' >"$destination.bd-issues"
  database_sql 'SELECT * FROM dependencies ORDER BY issue_id, id, type' |
    canonical_rows >"$destination.dependencies"
  database_sql 'SELECT * FROM events ORDER BY id' | canonical_rows >"$destination.events"
  database_sql 'SELECT actor, COUNT(*) AS event_count FROM events GROUP BY actor ORDER BY actor' |
    jq -S '.rows | map(.event_count |= tostring)' >"$destination.actors"
  run_dolt_in "$active_data/$active_database" log --oneline >"$destination.history"
}

assert_expected_actors() {
  local snapshot="$1" actor
  for actor in claude codex human; do
    jq -e --arg actor "$actor" 'any(.[]; .actor == $actor)' "$snapshot.actors" \
      >/dev/null || fail "source snapshot omitted expected actor $actor"
  done
}

compare_snapshots() {
  local expected="$1" actual="$2" label="$3" component
  for component in \
    actors \
    bd-issues \
    dependencies \
    events \
    head \
    history \
    issues \
    tables; do
    if ! cmp "$expected.$component" "$actual.$component"; then
      diff -u "$expected.$component" "$actual.$component" >&2 || :
      fail "$label differs in $component"
    fi
  done
}

run_scenario() {
  local scenario_index="$1"
  local blocker_id child_id epic_id replacement_remote_ref restored_bot_id
  local lock_fd restored_human_id source_remote_ref writer

  scenario_root="$probe_root/run-$scenario_index"
  ledger_path="$scenario_root/ledger.git"
  repository_lock="$scenario_root/repository.lock"
  install -d -m 0700 "$ledger_path"
  git -C "$ledger_path" init -q --bare
  git -C "$scenario_root" init -q -b main source
  git -C "$scenario_root/source" config beads.role maintainer
  git -C "$scenario_root/source" config user.email probe@example.invalid
  git -C "$scenario_root/source" config user.name Probe
  git -C "$scenario_root/source" commit -q --allow-empty -m seed
  git -C "$scenario_root/source" push -q "file://$ledger_path" main:main
  git -C "$scenario_root/source" worktree add -q -b linked "$scenario_root/linked"
  source_expected_head="$(git -C "$scenario_root/source" rev-parse HEAD)"
  linked_expected_head="$(git -C "$scenario_root/linked" rev-parse HEAD)"
  source_expected_config="$scenario_root/source-config.expected"
  git -C "$scenario_root/source" config --local --list | sort >"$source_expected_config"
  exec {lock_fd}>"$repository_lock"
  flock "$lock_fd"
  if flock -n "$repository_lock" true; then
    fail "a competing client acquired the repository lock"
  fi
  flock -u "$lock_fd"
  exec {lock_fd}>&-
  flock -n "$repository_lock" true || fail "the repository lock remained held"

  activate_phase primary "$((scenario_index * 3))" true
  locked_init source-init \
    init \
    --database "$active_database" \
    --external \
    --init-if-missing \
    --non-interactive \
    --prefix recovery \
    --remote "file://$ledger_path" \
    --server \
    --server-host 127.0.0.1 \
    --server-port "$server_port" \
    --skip-agents \
    --skip-hooks

  epic_id="$(locked_mutation create-epic "$scenario_root/source" human \
    create "Recovery epic $scenario_index" \
    --description "human-authored recovery root" \
    --labels recovery,root \
    --silent \
    --type epic)"
  blocker_id="$(locked_mutation create-blocker "$scenario_root/linked" codex \
    create "Recovery blocker $scenario_index" \
    --description "bot-authored prerequisite" \
    --silent \
    --type task)"
  child_id="$(locked_mutation create-child "$scenario_root/source" claude \
    create "Recovery child $scenario_index" \
    --description "child with relationships" \
    --parent "$epic_id" \
    --silent)"
  locked_mutation add-dependency "$scenario_root/linked" claude \
    dep add "$child_id" "$blocker_id" >/dev/null
  locked_mutation update-child "$scenario_root/source" human \
    update "$child_id" \
    --add-label verified \
    --assignee operator \
    --status in_progress >/dev/null
  locked_mutation close-blocker "$scenario_root/linked" codex \
    close "$blocker_id" --reason "recovery fixture complete" >/dev/null

  for writer in $(seq 1 2); do
    locked_mutation "source-writer-$writer" "$scenario_root/source" "codex-$writer" \
      create "source recovery writer $scenario_index/$writer" --silent >/dev/null
    locked_mutation "linked-writer-$writer" "$scenario_root/linked" "claude-$writer" \
      create "linked recovery writer $scenario_index/$writer" --silent >/dev/null
  done

  snapshot_phase "$scenario_root/source"
  assert_expected_actors "$scenario_root/source"
  source_remote_ref="$(publish_locked absent source-push)" ||
    fail "source pusher rejected a clean initial publication"
  if publish_locked "not-$source_remote_ref" divergence-control >/dev/null 2>&1; then
    fail "pusher accepted a divergent expected remote"
  fi
  [[ $(remote_ref) == "$source_remote_ref" ]] ||
    fail "divergence control changed the remote ref"
  stop_server

  activate_phase replacement "$((scenario_index * 3 + 1))" false
  locked_bootstrap replacement-bootstrap
  snapshot_phase "$scenario_root/replacement"
  compare_snapshots "$scenario_root/source" "$scenario_root/replacement" \
    "replacement restore"
  run_bd show "$epic_id" --json >/dev/null || fail "replacement omitted the epic"
  run_bd show "$child_id" --json >/dev/null || fail "replacement omitted the child"
  run_bd show "$blocker_id" --json >/dev/null || fail "replacement omitted the blocker"

  restored_human_id="$(locked_mutation restored-human "$active_cwd" human \
    create "Restored human write $scenario_index" \
    --description "written after clean recovery" \
    --silent)"
  restored_bot_id="$(locked_mutation restored-bot "$active_cwd" codex \
    create "Restored bot write $scenario_index" \
    --description "bot write after clean recovery" \
    --silent)"
  locked_mutation restored-dependency "$active_cwd" codex \
    dep add "$restored_bot_id" "$restored_human_id" >/dev/null
  locked_mutation restored-update "$active_cwd" human \
    update "$restored_human_id" \
    --add-label post-restore \
    --status in_progress >/dev/null
  snapshot_phase "$scenario_root/replacement-written"
  replacement_remote_ref="$(publish_locked "$source_remote_ref" replacement-push)" ||
    fail "replacement pusher rejected a clean forward publication"
  [[ $replacement_remote_ref != "$source_remote_ref" ]] ||
    fail "replacement publication did not advance the remote ref"
  stop_server

  activate_phase verification "$((scenario_index * 3 + 2))" false
  locked_bootstrap verification-bootstrap
  snapshot_phase "$scenario_root/verification"
  compare_snapshots "$scenario_root/replacement-written" "$scenario_root/verification" \
    "third restore"
  run_bd show "$restored_human_id" --json >/dev/null ||
    fail "third restore omitted the human-authored write"
  run_bd show "$restored_bot_id" --json >/dev/null ||
    fail "third restore omitted the bot-authored write"
  [[ $(remote_ref) == "$replacement_remote_ref" ]] ||
    fail "third restore changed the remote ref"
  if [[ $scenario_index == 3 ]]; then
    dirty_preflight_control "$restored_human_id"
  fi
  stop_server

  printf 'run_%s_source_ref=%s\n' "$scenario_index" "$source_remote_ref"
  printf 'run_%s_replacement_ref=%s\n' "$scenario_index" "$replacement_remote_ref"
  printf 'run_%s_third_restore=exact\n' "$scenario_index"
}

install -d -m 0700 \
  "$probe_root/git-home/.cache" \
  "$probe_root/git-home/.config" \
  "$probe_root/git-home/.local/share" \
  "$probe_root/git-home/dolt-root"
for setting in metrics.disabled versioncheck.disabled; do
  env -i \
    HOME="$probe_root/git-home" \
    DOLT_DISABLE_EVENT_FLUSH=1 \
    DOLT_ROOT_PATH="$probe_root/git-home/dolt-root" \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_TERMINAL_PROMPT=0 \
    PATH="$PATH" \
    "$dolt_bin" config --global --add "$setting" true >/dev/null
done
bd_version="$(
  env -i \
    HOME="$probe_root/git-home" \
    XDG_CACHE_HOME="$probe_root/git-home/.cache" \
    XDG_CONFIG_HOME="$probe_root/git-home/.config" \
    XDG_DATA_HOME="$probe_root/git-home/.local/share" \
    BD_DISABLE_EVENT_FLUSH=1 \
    BD_DISABLE_METRICS=1 \
    DOLT_DISABLE_EVENT_FLUSH=1 \
    DOLT_ROOT_PATH="$probe_root/git-home/dolt-root" \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_TERMINAL_PROMPT=0 \
    PATH="$PATH" \
    timeout --kill-after=5 --signal=TERM 120 "$bd_bin" --version
)"
dolt_version="$(
  env -i \
    HOME="$probe_root/git-home" \
    DOLT_DISABLE_EVENT_FLUSH=1 \
    DOLT_ROOT_PATH="$probe_root/git-home/dolt-root" \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_TERMINAL_PROMPT=0 \
    PATH="$PATH" \
    timeout --kill-after=5 --signal=TERM 120 "$dolt_bin" version | sed -n '1p'
)"
[[ $bd_version == "bd version 1.2.2 (dev)" ]] || fail "unexpected bd: $bd_version"
[[ $dolt_version == "dolt version 2.2.3" ]] || fail "unexpected Dolt: $dolt_version"

printf 'bd=%s\n' "$bd_version"
printf 'dolt=%s\n' "$dolt_version"
for scenario_index in 1 2 3; do
  run_scenario "$scenario_index"
done
printf 'serialized_recovery_runs=3\n'
printf 'constraint_violations=0\n'
printf 'dependency_orphans=0\n'
printf 'event_orphans=0\n'
