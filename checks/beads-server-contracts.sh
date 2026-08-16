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
        port_is_open "$server_port"; then
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

run_bd() {
  env -i \
    HOME="$probe_root/home" \
    XDG_CACHE_HOME="$probe_root/home/.cache" \
    XDG_CONFIG_HOME="$probe_root/home/.config" \
    XDG_DATA_HOME="$probe_root/home/.local/share" \
    BEADS_DIR="$probe_root/state" \
    BEADS_DOLT_SERVER_PORT="$server_port" \
    PATH="$PATH" \
    timeout --kill-after=5 --signal=TERM 120 "$bd_bin" "$@"
}

run_bd_without_port() {
  env -i \
    HOME="$probe_root/home" \
    XDG_CACHE_HOME="$probe_root/home/.cache" \
    XDG_CONFIG_HOME="$probe_root/home/.config" \
    XDG_DATA_HOME="$probe_root/home/.local/share" \
    BEADS_DIR="$probe_root/state" \
    PATH="$PATH" \
    timeout --kill-after=5 --signal=TERM 120 "$bd_bin" "$@"
}

install -d -m 0700 \
  "$probe_root/cwd" \
  "$probe_root/dolt-data" \
  "$probe_root/dolt-root" \
  "$probe_root/home/.cache" \
  "$probe_root/home/.config/beads" \
  "$probe_root/home/.local/share" \
  "$probe_root/state"
install -m 0600 /dev/stdin "$probe_root/state/config.yaml" <<'YAML'
no-git-ops: true
YAML
install -m 0644 /dev/stdin "$probe_root/home/.config/beads/credentials" <<EOF
[127.0.0.1:PORT]
password = fixture-file-password
EOF

start_server 0
database_name="contract_$$_$(date +%s%N)"
sed -i "s/:PORT]/:$server_port]/" "$probe_root/home/.config/beads/credentials"
sed -i 's/password = fixture-file-password/password =/' \
  "$probe_root/home/.config/beads/credentials"

(
  cd "$probe_root/cwd"
  run_bd init \
    --database "$database_name" \
    --external \
    --init-if-missing \
    --non-interactive \
    --prefix external \
    --server \
    --server-host 127.0.0.1 \
    --server-port "$server_port" \
    --skip-agents \
    --skip-hooks
) >"$probe_root/init.out" 2>&1

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

git -C "$probe_root" init -q -b main source
git -C "$probe_root/source" config user.email probe@example.invalid
git -C "$probe_root/source" config user.name Probe
git -C "$probe_root/source" commit -q --allow-empty -m seed
git -C "$probe_root/source" worktree add -q -b linked "$probe_root/linked"

writer_labels=()
writer_processes=()
started_ns="$(date +%s%N)"
for writer in $(seq 1 8); do
  (
    cd "$probe_root/source"
    run_bd --dolt-auto-commit on create "main server writer $writer" --silent
  ) >"$probe_root/main-$writer.out" 2>&1 &
  writer_processes+=("$!")
  writer_labels+=("main-$writer")
  (
    cd "$probe_root/linked"
    run_bd --dolt-auto-commit on create "linked server writer $writer" --silent
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

crash_id="$(run_bd --dolt-auto-commit off create "crash-window survivor" --silent)"
old_port="$server_port"
kill -KILL "$server_pid"
wait "$server_pid" 2>/dev/null || :
server_pid=""
jq -e --argjson port "$old_port" '.dolt_server_port == $port' \
  "$probe_root/state/metadata.json" >/dev/null ||
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

printf 'bd=%s\n' "$("$bd_bin" --version)"
printf 'dolt=%s\n' "$(HOME="$probe_root/home" "$dolt_bin" version | head -n 1)"
printf 'server_port_before=%s\n' "$old_port"
printf 'server_port_after=%s\n' "$server_port"
printf 'writers=16\n'
printf 'elapsed_ms=%s\n' "$elapsed_ms"
printf 'nothing_to_commit_warnings=%s\n' "$warning_count"
printf 'external_status=%s\n' "$(jq -c . <<<"$status")"
printf 'offline_write_failure=%s\n' \
  "$(grep -Em1 'connection refused|connect:' "$probe_root/offline-write.out")"
printf 'stale_port_failure=%s\n' \
  "$(grep -Em1 'connection refused|connect:' "$probe_root/stale-port.out")"
