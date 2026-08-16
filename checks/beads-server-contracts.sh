#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

if (($# != 2)); then
  printf 'usage: %s /path/to/bd /path/to/dolt\n' "$0" >&2
  exit 2
fi

bd_bin="$1"
dolt_bin="$2"
probe_root="$(mktemp -d "${TMPDIR:-/tmp}/beads-server-contracts.XXXXXXXX")"
managed_initialized=0
server_pid=""
server_port=""
writer_processes=()

fail() {
  printf 'beads-server-contracts: %s\n' "$1" >&2
  exit 1
}

stop_server() {
  if [[ -n $server_pid ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || :
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
  local live writer_pid
  if ((managed_initialized)); then
    run_managed_bd dolt stop >/dev/null 2>&1 || :
  fi
  for writer_pid in "${writer_processes[@]}"; do
    if kill -0 "$writer_pid" 2>/dev/null; then
      kill "$writer_pid" 2>/dev/null || :
    fi
  done
  for _ in $(seq 1 100); do
    live=0
    for writer_pid in "${writer_processes[@]}"; do
      if kill -0 "$writer_pid" 2>/dev/null; then
        live=1
      fi
    done
    ((live == 0)) && break
    sleep 0.05
  done
  for writer_pid in "${writer_processes[@]}"; do
    if kill -0 "$writer_pid" 2>/dev/null; then
      kill -KILL "$writer_pid" 2>/dev/null || :
    fi
    wait "$writer_pid" 2>/dev/null || :
  done
  stop_server
  case "$probe_root" in
  "${TMPDIR:-/tmp}"/beads-server-contracts.*)
    rm -rf -- "$probe_root"
    ;;
  *)
    printf 'refusing to clean unexpected probe root: %s\n' "$probe_root" >&2
    ;;
  esac
}
trap cleanup EXIT

port_is_open() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

dolt_server_is_ours() {
  (
    cd "$probe_root/dolt-data"
    env -i \
      HOME="$probe_root/home" \
      DOLT_DISABLE_EVENT_FLUSH=1 \
      DOLT_ROOT_PATH="$probe_root/dolt-root" \
      PATH="$PATH" \
      timeout --kill-after=1 --signal=TERM 2 "$dolt_bin" \
      sql -r json -q 'SELECT 1 AS ready'
  ) 2>/dev/null | jq -e '.rows == [{"ready": "1"}]' >/dev/null
}

start_server() {
  local candidate info log_offset
  log_offset="$1"
  info="$probe_root/dolt-data/.dolt/sql-server.info"
  for candidate in $(seq "$((43000 + ($$ % 1000) + log_offset))" 44999); do
    if port_is_open "$candidate"; then
      continue
    fi
    if [[ -e $info ]]; then
      rm -f -- "$info"
    fi
    server_port="$candidate"
    (
      cd "$probe_root/dolt-data"
      env -i \
        HOME="$probe_root/home" \
        DOLT_DISABLE_EVENT_FLUSH=1 \
        DOLT_ROOT_PATH="$probe_root/dolt-root" \
        PATH="$PATH" \
        "$dolt_bin" sql-server \
        --host 127.0.0.1 \
        --loglevel debug \
        --port "$server_port"
    ) >"$probe_root/server-$server_port.log" 2>&1 &
    server_pid="$!"
    for _ in $(seq 1 200); do
      if kill -0 "$server_pid" 2>/dev/null &&
        [[ -f $info ]] &&
        [[ $(<"$info") == "$server_pid:$server_port:"* ]] &&
        port_is_open "$server_port" &&
        dolt_server_is_ours; then
        return
      fi
      if ! kill -0 "$server_pid" 2>/dev/null; then
        break
      fi
      sleep 0.05
    done
    wait "$server_pid" 2>/dev/null || :
    server_pid=""
  done
  fail "could not start a loopback Dolt server"
}

run_bd_in() {
  local cwd="$1" state="$2"
  shift 2
  (
    cd "$cwd"
    env -i \
      HOME="$probe_root/home" \
      XDG_CACHE_HOME="$probe_root/home/.cache" \
      XDG_CONFIG_HOME="$probe_root/home/.config" \
      XDG_DATA_HOME="$probe_root/home/.local/share" \
      BEADS_DIR="$state" \
      BEADS_DOLT_SERVER_PORT="$server_port" \
      BD_DOLT_AUTO_PUSH=false \
      PATH="$PATH" \
      timeout --kill-after=5 --signal=TERM 120 "$bd_bin" "$@"
  )
}

run_bd() {
  run_bd_in "$probe_root/cwd" "$probe_root/module-root/.beads" "$@"
}

run_bd_without_port() {
  (
    cd "$probe_root/cwd"
    env -i \
      HOME="$probe_root/home" \
      XDG_CACHE_HOME="$probe_root/home/.cache" \
      XDG_CONFIG_HOME="$probe_root/home/.config" \
      XDG_DATA_HOME="$probe_root/home/.local/share" \
      BEADS_DIR="$probe_root/module-root/.beads" \
      BD_DOLT_AUTO_PUSH=false \
      PATH="$PATH" \
      timeout --kill-after=5 --signal=TERM 120 "$bd_bin" "$@"
  )
}

run_dolt_in() {
  local cwd="$1"
  shift
  (
    cd "$cwd"
    env -i \
      HOME="$probe_root/home" \
      DOLT_DISABLE_EVENT_FLUSH=1 \
      DOLT_ROOT_PATH="$probe_root/dolt-root" \
      PATH="$PATH" \
      timeout --kill-after=5 --signal=TERM 120 "$dolt_bin" "$@"
  )
}

run_bootstrap_bd() {
  (
    cd "$probe_root/bootstrap-root"
    env -i \
      HOME="$probe_root/bootstrap-home" \
      XDG_CACHE_HOME="$probe_root/bootstrap-home/.cache" \
      XDG_CONFIG_HOME="$probe_root/bootstrap-home/.config" \
      XDG_DATA_HOME="$probe_root/bootstrap-home/.local/share" \
      BEADS_DIR="$probe_root/bootstrap-root/.beads" \
      BEADS_DOLT_SERVER_DATABASE="$bootstrap_database" \
      BEADS_DOLT_SERVER_HOST=127.0.0.1 \
      BEADS_DOLT_SERVER_MODE=1 \
      BEADS_DOLT_SERVER_PORT="$server_port" \
      BD_DOLT_AUTO_PUSH=false \
      PATH="$PATH" \
      timeout --kill-after=5 --signal=TERM 120 "$bd_bin" "$@"
  )
}

run_managed_bd() {
  (
    cd "$probe_root/managed-cwd"
    env -i \
      HOME="$probe_root/managed-home" \
      XDG_CACHE_HOME="$probe_root/managed-home/.cache" \
      XDG_CONFIG_HOME="$probe_root/managed-home/.config" \
      XDG_DATA_HOME="$probe_root/managed-home/.local/share" \
      BEADS_DIR="$probe_root/managed-state" \
      PATH="$PATH" \
      timeout --kill-after=5 --signal=TERM 120 "$bd_bin" "$@"
  )
}

install -d -m 0700 \
  "$probe_root/cwd" \
  "$probe_root/dolt-data" \
  "$probe_root/dolt-root" \
  "$probe_root/home/.cache" \
  "$probe_root/home/.config/beads" \
  "$probe_root/home/.local/share" \
  "$probe_root/ledger.git" \
  "$probe_root/module-root/.beads"
install -m 0600 /dev/stdin "$probe_root/module-root/.beads/config.yaml" <<'YAML'
dolt:
  auto-push: false
export:
  auto: false
  git-add: false
no-git-ops: true
YAML
install -m 0644 /dev/stdin "$probe_root/home/.config/beads/credentials" <<EOF
[127.0.0.1:PORT]
password = fixture-file-password
EOF

git -C "$probe_root/ledger.git" init -q --bare
if git ls-remote --exit-code --heads "file://$probe_root/ledger.git" \
  >"$probe_root/unborn-heads.out" 2>&1; then
  fail "unborn ledger unexpectedly passed the branch guard"
else
  unborn_remote_rc="$?"
fi
[[ $unborn_remote_rc == 2 ]] || fail "unborn ledger branch guard returned $unborn_remote_rc"
git -C "$probe_root" init -q -b main source
git -C "$probe_root/source" config user.email probe@example.invalid
git -C "$probe_root/source" config user.name Probe
git -C "$probe_root/source" commit -q --allow-empty -m seed
git -C "$probe_root/source" push -q "file://$probe_root/ledger.git" main:main
git ls-remote --exit-code --heads "file://$probe_root/ledger.git" \
  refs/heads/main >"$probe_root/seeded-heads.out" || fail "seeded ledger failed the branch guard"
git -C "$probe_root/source" worktree add -q -b linked "$probe_root/linked"
source_head="$(git -C "$probe_root/source" rev-parse HEAD)"
git -C "$probe_root/source" config --local --list | sort >"$probe_root/source-config.before"

start_server 0
database_name="contract_$$_$(date +%s%N)"
sed -i "s/:PORT]/:$server_port]/" "$probe_root/home/.config/beads/credentials"
sed -i 's/password = fixture-file-password/password =/' \
  "$probe_root/home/.config/beads/credentials"

run_bd init \
  --database "$database_name" \
  --external \
  --init-if-missing \
  --non-interactive \
  --prefix external \
  --remote "file://$probe_root/ledger.git" \
  --server \
  --server-host 127.0.0.1 \
  --server-port "$server_port" \
  --skip-agents \
  --skip-hooks >"$probe_root/init.out" 2>&1

[[ -z $(find "$probe_root/cwd" -mindepth 1 -print -quit) ]] ||
  fail "composed init wrote into its neutral cwd"
[[ $(run_bd where --json | jq -r .path) == "$probe_root/module-root/.beads" ]] ||
  fail "composed init resolved the wrong workspace"
config_json="$(run_bd config show --json)"
jq -e \
  '.[] | select(.key == "dolt.auto-push" and .value == "false" and
    .source == "env: BD_DOLT_AUTO_PUSH")' \
  <<<"$config_json" >/dev/null || fail "BD_DOLT_AUTO_PUSH=false is not effective"
for expected in \
  export.auto=false \
  export.git-add=false \
  no-git-ops=true; do
  key="${expected%%=*}"
  value="${expected#*=}"
  jq -e --arg key "$key" --arg value "$value" \
    '.[] | select(.key == $key and (.value | tostring) == $value and
      (.source | endswith("config.yaml")))' \
    <<<"$config_json" >/dev/null || fail "inert config $expected changed"
done
actual_remote="$(run_bd config show --json |
  jq -r '.[] | select(.key == "sync.remote") | .value')"
[[ $actual_remote == "file://$probe_root/ledger.git" ]] ||
  fail "composed init changed the ledger URL"
expected_remote="[{\"name\":\"origin\",\"url\":\"git+file://$probe_root/ledger.git\",\"sql_url\":\"git+file://$probe_root/ledger.git\",\"status\":\"ok\"}]"
actual_remote="$(run_bd dolt remote list --json |
  jq -c '[.[] | {name, url, sql_url, status}]')"
[[ $actual_remote == "$expected_remote" ]] || fail "composed init remote set changed"
if git -C "$probe_root/ledger.git" rev-parse --verify refs/dolt/data >/dev/null 2>&1; then
  fail "composed init published without an explicit push"
fi
cache_root="$probe_root/dolt-data/$database_name/.dolt/git-remote-cache"
[[ ! -e $cache_root ]] || fail "failed clone unexpectedly retained its cache repository"

show="$(run_bd dolt show --json)"
jq -e \
  --arg database "$database_name" \
  --argjson port "$server_port" \
  '.connection_ok == true and .database == $database and
    .host == "127.0.0.1" and .port == $port' \
  <<<"$show" >/dev/null || fail "external server readiness shape changed"
run_bd list --json >/dev/null 2>"$probe_root/broad-credentials.out"
grep -Fq 'has overly permissive permissions (0644)' "$probe_root/broad-credentials.out" ||
  fail "broad credentials mode did not warn"
chmod 600 "$probe_root/home/.config/beads/credentials"
run_bd list --json >/dev/null 2>"$probe_root/restricted-password.out"
if grep -Fq 'overly permissive permissions' "$probe_root/restricted-password.out"; then
  fail "mode-0600 credentials file still warned"
fi

status="$(run_bd dolt status --json)"
jq -e '.running == false and .pid == 0 and .port == 0' \
  <<<"$status" >/dev/null || fail "bd unexpectedly adopted the external server"
if run_bd dolt stop >"$probe_root/stop.out" 2>&1; then
  fail "bd stopped a supervisor-owned external server"
fi

writer_labels=()
writer_processes=()
started_ns="$(date +%s%N)"
for writer in $(seq 1 8); do
  (
    run_bd_in "$probe_root/source" "$probe_root/module-root/.beads" \
      --dolt-auto-commit on create "main server writer $writer" --silent
  ) >"$probe_root/main-$writer.out" 2>&1 &
  writer_processes+=("$!")
  writer_labels+=("main-$writer")
  (
    run_bd_in "$probe_root/linked" "$probe_root/module-root/.beads" \
      --dolt-auto-commit on create "linked server writer $writer" --silent
  ) >"$probe_root/linked-$writer.out" 2>&1 &
  writer_processes+=("$!")
  writer_labels+=("linked-$writer")
done
writer_failed=0
for index in "${!writer_processes[@]}"; do
  if ! wait "${writer_processes[$index]}"; then
    printf 'beads-server-contracts: server writer %s failed\n' \
      "${writer_labels[$index]}" >&2
    writer_failed=1
  fi
done
writer_processes=()
((writer_failed == 0)) || fail "one or more server writers failed"
elapsed_ms="$((($(date +%s%N) - started_ns) / 1000000))"
issue_count="$(run_bd list --json | jq length)"
[[ $issue_count == 16 ]] || fail "server writers persisted $issue_count/16 rows"
warning_count="$(grep -hFc 'nothing to commit' "$probe_root"/server-*.log || :)"
[[ $(git -C "$probe_root/source" rev-parse HEAD) == "$source_head" ]] ||
  fail "server writers changed source HEAD"
[[ -z $(git -C "$probe_root/source" status --short --untracked-files=all) ]] ||
  fail "server writers changed the source worktree"
git -C "$probe_root/source" config --local --list | sort >"$probe_root/source-config.after"
cmp "$probe_root/source-config.before" "$probe_root/source-config.after" ||
  fail "server writers changed source Git config"
if git -C "$probe_root/ledger.git" rev-parse --verify refs/dolt/data >/dev/null 2>&1; then
  fail "server writers published without an explicit push"
fi
if run_bd dolt push >"$probe_root/explicit-push.out" 2>&1; then
  fail "poison-window server SQL push unexpectedly succeeded"
fi
grep -Fq "not a git repository:" "$probe_root/explicit-push.out" ||
  fail "server-backed Git remote push failure changed"
grep -Eq 'git-remote-cache/.+/repo.git' "$probe_root/explicit-push.out" ||
  fail "server-backed push did not identify its unusable cache"
if git -C "$probe_root/ledger.git" rev-parse --verify refs/dolt/data >/dev/null 2>&1; then
  fail "failed server push still created refs/dolt/data"
fi
[[ ! -e $cache_root ]] || fail "poisoned server push unexpectedly rebuilt its cache"

metadata_database="$(jq -er '.dolt_database | select(type == "string" and length > 0)' \
  "$probe_root/module-root/.beads/metadata.json")"
[[ $metadata_database == "$database_name" ]] ||
  fail "metadata database does not match the initialized database"
pusher_lock="$probe_root/module-root/beads-pusher.lock"
exec {pusher_lock_fd}>"$pusher_lock"
flock "$pusher_lock_fd"
if flock -n "$pusher_lock" true; then
  fail "competing pusher acquired the repository singleton lock"
fi
run_dolt_in "$probe_root/dolt-data/$metadata_database" \
  push --set-upstream origin main >"$probe_root/raw-push.out" 2>&1
flock -u "$pusher_lock_fd"
exec {pusher_lock_fd}>&-
flock -n "$pusher_lock" true || fail "pusher lock remained held after release"

mapfile -t cache_repositories < <(
  find "$cache_root" -type d -path '*/repo.git' -print | sort
)
((${#cache_repositories[@]} == 1)) ||
  fail "module pusher did not create exactly one cache repository"
git --git-dir="${cache_repositories[0]}" rev-parse --is-bare-repository |
  grep -Fxq true || fail "module pusher cache is not a bare Git repository"
git --git-dir="${cache_repositories[0]}" fsck --connectivity-only >/dev/null ||
  fail "module pusher cache is unusable"
git -C "$probe_root/ledger.git" rev-parse --verify refs/dolt/data >/dev/null ||
  fail "module pusher did not publish refs/dolt/data"
run_bd dolt push >"$probe_root/healed-server-push.out" 2>&1
grep -Fq "Push complete." "$probe_root/healed-server-push.out" ||
  fail "raw push did not heal the live server push path"
published_ref="$(git -C "$probe_root/ledger.git" rev-parse refs/dolt/data)"

install -d -m 0700 \
  "$probe_root/bootstrap-home/.cache" \
  "$probe_root/bootstrap-home/.config" \
  "$probe_root/bootstrap-home/.local/share" \
  "$probe_root/bootstrap-root/.beads"
install -m 0600 /dev/stdin "$probe_root/bootstrap-root/.beads/config.yaml" <<EOF
dolt:
  auto-push: false
export:
  auto: false
  git-add: false
no-git-ops: true
sync:
  remote: file://$probe_root/ledger.git
EOF
bootstrap_database="bootstrap_$$_$(date +%s%N)"
run_bd list --json | jq -r '.[].id' | sort >"$probe_root/source-issues"
run_dolt_in "$probe_root/dolt-data/$metadata_database" log --oneline \
  >"$probe_root/source-history"
run_bootstrap_bd bootstrap --non-interactive --json \
  >"$probe_root/bootstrap.out" 2>&1
[[ $(run_bootstrap_bd where --json | jq -r .path) == "$probe_root/bootstrap-root/.beads" ]] || fail "bootstrap resolved the wrong workspace"
run_bootstrap_bd list --json | jq -r '.[].id' | sort >"$probe_root/bootstrap-issues"
cmp "$probe_root/source-issues" "$probe_root/bootstrap-issues" ||
  fail "bootstrap did not restore the published issues"
run_dolt_in "$probe_root/dolt-data/$bootstrap_database" log --oneline \
  >"$probe_root/bootstrap-history"
cmp "$probe_root/source-history" "$probe_root/bootstrap-history" ||
  fail "bootstrap did not restore the published history"
run_bootstrap_bd vc log --json >"$probe_root/vc-log.out" 2>&1
grep -Fq "Available Commands:" "$probe_root/vc-log.out" ||
  fail "bd vc log no longer exhibits the help-with-success trap"
[[ $(git -C "$probe_root/ledger.git" rev-parse refs/dolt/data) == "$published_ref" ]] ||
  fail "bootstrap published unexpectedly"
if run_bootstrap_bd bootstrap --non-interactive \
  >"$probe_root/bootstrap-again.out" 2>&1; then
  fail "bootstrap with sync.remote unexpectedly reran idempotently"
fi
grep -Eiq 'already exists|database exists' "$probe_root/bootstrap-again.out" ||
  fail "repeat bootstrap failure shape changed"

crash_id="$(run_bd --dolt-auto-commit off create "crash-window survivor" --silent)"
if [[ $(git -C "$probe_root/ledger.git" rev-parse refs/dolt/data) != "$published_ref" ]]; then
  fail "local crash-window write published automatically"
fi
old_port="$server_port"
kill -KILL "$server_pid"
wait "$server_pid" 2>/dev/null || :
server_pid=""
jq -e --argjson port "$old_port" '.dolt_server_port == $port' \
  "$probe_root/module-root/.beads/metadata.json" >/dev/null ||
  fail "metadata did not retain the initialized server port"
if run_bd create "offline write must fail" --silent \
  >"$probe_root/offline-write.out" 2>&1; then
  fail "write without a server unexpectedly succeeded"
fi
grep -Eq 'connection refused|connect:' "$probe_root/offline-write.out" ||
  fail "offline write did not fail loudly"
grep -Fq "127.0.0.1:$old_port" "$probe_root/offline-write.out" ||
  fail "offline write did not name the recorded endpoint"
start_server 1000
[[ $server_port != "$old_port" ]] || fail "server restart reused the stale port"
if run_bd_without_port list --json >"$probe_root/stale-port.out" 2>&1; then
  fail "stale recorded server port unexpectedly connected"
fi
grep -Eq 'connection refused|connect:' "$probe_root/stale-port.out" ||
  fail "stale server port did not fail loudly"
grep -Fq "127.0.0.1:$old_port" "$probe_root/stale-port.out" ||
  fail "stale server failure did not name the recorded endpoint"
run_bd show "$crash_id" --json >/dev/null ||
  fail "uncommitted row did not survive server restart"
run_bd dolt commit -m "post-restart checkpoint" >/dev/null
[[ $(git -C "$probe_root/ledger.git" rev-parse refs/dolt/data) == "$published_ref" ]] ||
  fail "restart or local checkpoint published in the background"
stop_server

# Native server ownership is qualified separately from the external topology.
# Init auto-starts one background server; a forced crash is not restarted until
# an explicit start, and status/stop/log residue remain project-local.
install -d -m 0700 \
  "$probe_root/managed-cwd" \
  "$probe_root/managed-home/.cache" \
  "$probe_root/managed-home/.config" \
  "$probe_root/managed-home/.local/share" \
  "$probe_root/managed-state"
install -m 0600 /dev/stdin "$probe_root/managed-state/config.yaml" <<'YAML'
no-git-ops: true
YAML
managed_initialized=1
run_managed_bd init \
  --non-interactive \
  --prefix managed \
  --server \
  --skip-agents \
  --skip-hooks >"$probe_root/managed-init.out" 2>&1
managed_status="$(run_managed_bd dolt status --json)"
jq -e '.running == true and .pid > 0 and .port > 0' \
  <<<"$managed_status" >/dev/null || fail "native server init did not start its process"
managed_pid="$(jq -r .pid <<<"$managed_status")"
managed_port="$(jq -r .port <<<"$managed_status")"
[[ -s $probe_root/managed-state/dolt-server.log ]] ||
  fail "native server did not retain a failure-diagnostic log"
for residue in dolt-server.lock dolt-server.log dolt-server.pid dolt-server.port; do
  [[ -f $probe_root/managed-state/$residue ]] ||
    fail "native server omitted $residue"
done
kill -KILL "$managed_pid"
for _ in $(seq 1 100); do
  if ! kill -0 "$managed_pid" 2>/dev/null; then
    break
  fi
  sleep 0.05
done
kill -0 "$managed_pid" 2>/dev/null && fail "native server ignored SIGKILL"
sleep 0.2
managed_status="$(run_managed_bd dolt status --json)"
jq -e '.running == false' <<<"$managed_status" >/dev/null ||
  fail "native server restarted automatically after a crash"
port_is_open "$managed_port" && fail "crashed native server left its port open"
run_managed_bd dolt start >"$probe_root/managed-restart.out"
managed_status="$(run_managed_bd dolt status --json)"
jq -e '.running == true and .pid > 0 and .port > 0' \
  <<<"$managed_status" >/dev/null || fail "explicit native restart failed"
run_managed_bd dolt stop >"$probe_root/managed-stop.out"
managed_status="$(run_managed_bd dolt status --json)"
jq -e '.running == false and .pid == 0 and .port == 0' \
  <<<"$managed_status" >/dev/null || fail "native server stop left a live process"
managed_initialized=0

printf 'bd=%s\n' "$("$bd_bin" --version)"
printf 'dolt=%s\n' "$(HOME="$probe_root/home" "$dolt_bin" version | head -n 1)"
printf 'server_port_before=%s\n' "$old_port"
printf 'server_port_after=%s\n' "$server_port"
printf 'managed_port=%s\n' "$managed_port"
printf 'writers=16\n'
printf 'elapsed_ms=%s\n' "$elapsed_ms"
printf 'nothing_to_commit_warnings=%s\n' "$warning_count"
printf 'module_push_ref=%s\n' "$published_ref"
printf 'bootstrap_database=%s\n' "$bootstrap_database"
printf 'bootstrap_rows=%s\n' "$(wc -l <"$probe_root/bootstrap-issues")"
printf 'pusher_singleton=exclusive_then_released\n'
printf 'server_push_after_raw=healed_without_restart\n'
printf 'server_remote_push_failure=%s\n' \
  "$(grep -Fm1 'not a git repository:' "$probe_root/explicit-push.out")"
printf 'external_status=%s\n' "$(jq -c . <<<"$status")"
printf 'offline_write_failure=%s\n' \
  "$(grep -Em1 'connection refused|connect:' "$probe_root/offline-write.out")"
printf 'stale_port_failure=%s\n' \
  "$(grep -Em1 'connection refused|connect:' "$probe_root/stale-port.out")"
