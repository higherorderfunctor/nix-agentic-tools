#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# usage: daemonlife.sh <probe> <port>
# codex:L2 — shared app-server daemon lifecycle, OFFLINE (fake provider, fresh CODEX_HOME).
# Starts `codex app-server daemon start` inside the scratch home (the daemon installs its own copy
# of the pinned binary under <home>/packages), then runs probes/<probe>/phases.txt, one step a line:
#   client <file.json>   asclient.py over wsuds.py (a daemon client that attaches, then
#                        disconnects when its probe ends); output in <results>/<file stem>/
#   queue <text>         `codex queue --thread <first client's thread> --message <text>`
#   tui <secs> <text>    the interactive TUI (attaches to the daemon) under tmux: submits <text>,
#                        then after <secs> kills the tmux session (the terminal goes away)
#   tui-embedded <secs> <text>   the same with `codex --no-daemon` (what the Nix wrapper runs)
#   server               a standalone `codex --no-daemon app-server --listen ws://127.0.0.1:<port+1>`
#   tui-remote <secs> <text>     the same TUI step with `--remote ws://127.0.0.1:<port+1>`
#   sleep <secs>
# Stops the daemon and its updater loop at the end (only processes whose argv points into the
# scratch home), deletes the installed binary copy, and prints the fake-provider requests.
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../common/pin.sh
source "$D/../common/pin.sh"
name="${1:?usage: daemonlife.sh <probe> <port>}"
port="${2:?port}"
work="${CODEX_WORK:-$(probe_workdir codex)}"
pkg="${CODEX_PKG:-$(probe_pkg chatgpt-codex)}"
codex="$pkg/bin/codex"
export CODEX_BIN="$codex"
if [[ ! -f $work/models_cache.json ]]; then
  python3 "$D/mkcache.py" "$(probe_pkg chatgpt-codex.src)" "$work/models_cache.json"
fi
P="$D/probes/$name"
R="$work/results/$name"
H="$R/home"
rm -rf "$R"
mkdir -p "$R/wire" "$H" "$work/plain"
sed -e "s|@PORT@|$port|g" -e "s|@PLAIN@|$work/plain|g" "$P/config.toml" >"$H/config.toml"
cp "$work/models_cache.json" "$H/models_cache.json"
python3 "$D/fp.py" "$port" "$R/wire" "$P/scenario.json" &
fp=$!
stop_daemon() {
  local up
  [[ -d $H/app-server-daemon ]] || return 0
  (cd "$work/plain" && CODEX_HOME="$H" timeout 60 "$codex" app-server daemon stop 2>&1 | tail -n1) || :
  up="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$H/app-server-daemon/daemon-updater.pid" 2>/dev/null || :)"
  if [[ -n $up ]] && tr '\0' '\n' <"/proc/$up/cmdline" 2>/dev/null | grep -qF "$H/"; then kill "$up" || :; fi
  cp "$H/app-server-daemon/daemon.stderr.log" "$R/daemon.stderr.log" 2>/dev/null || :
  rm -rf "$H/packages" # the daemon's installed binary copy (~600 MB); not evidence
}
srv=""
trap 'tmux -L dmu-dl kill-server 2>/dev/null || :; [[ -z $srv ]] || kill "$srv" 2>/dev/null || :; stop_daemon >/dev/null 2>&1 || :; kill "$fp" 2>/dev/null || :' EXIT
sleep 0.5
start=$(date +%s.%N)
(cd "$work/plain" && CODEX_HOME="$H" FAKE_KEY=x timeout 120 "$codex" app-server daemon start >"$R/daemon-start.json" 2>"$R/daemon-start.err")
stamp() { printf '+%5.1fs %s\n' "$(echo "$(date +%s.%N) - $start" | bc)" "$*"; }
first=""
while read -r op arg; do
  [[ -z $op || $op == \#* ]] && continue
  case $op in
  client)
    stamp "client $arg"
    python3 "$D/asclient.py" "$H" "$R/${arg%.json}" "$work/plain" "$P/$arg"
    [[ -n $first ]] || first="$R/${arg%.json}/thread_id"
    ;;
  queue)
    stamp "queue $arg"
    (cd "$work/plain" && CODEX_HOME="$H" timeout 60 "$codex" queue --thread "$(cat "$first")" --message "$arg" >"$R/queue.out" 2>&1) || stamp "queue exit $?"
    ;;
  server)
    stamp "server ws://127.0.0.1:$((port + 1))"
    (cd "$work/plain" && exec env CODEX_HOME="$H" FAKE_KEY=x "$codex" --no-daemon app-server --listen "ws://127.0.0.1:$((port + 1))" 2>"$R/server.err") &
    srv=$!
    sleep 2
    ;;
  tui | tui-embedded | tui-remote)
    stamp "$op $arg"
    read -r secs text <<<"$arg"
    flags=()
    if [[ $op == tui-embedded ]]; then flags=(--no-daemon); fi
    if [[ $op == tui-remote ]]; then flags=(--remote "ws://127.0.0.1:$((port + 1))"); fi
    tmux -L dmu-dl new-session -d -s tui -x 200 -y 50 -c "$work/plain" env CODEX_HOME="$H" FAKE_KEY=x "$codex" "${flags[@]}"
    n=40
    until tmux -L dmu-dl capture-pane -p -t tui | grep -qF "Ask Codex to do anything"; do
      ((n-- > 0)) || {
        stamp "tui: no composer"
        false
      }
      sleep 1
    done
    sleep 2 # a daemon-backed composer can draw before its connection is ready
    tmux -L dmu-dl send-keys -t tui "$text"
    sleep 0.5
    tmux -L dmu-dl send-keys -t tui Enter
    sleep "$secs"
    tmux -L dmu-dl capture-pane -p -t tui >"$R/tui-pane.txt"
    stamp "tui killed"
    tmux -L dmu-dl kill-session -t tui
    ;;
  sleep)
    stamp "sleep $arg"
    sleep "$arg"
    ;;
  *)
    printf 'unknown step: %s\n' "$op" >&2
    false
    ;;
  esac
done <"$P/phases.txt"
stamp "done"
stop_daemon
python3 - "$R/wire/log.jsonl" "$start" <<'EOF'
import json, sys
t0 = float(sys.argv[2])
for line in open(sys.argv[1]):
    d = json.loads(line)
    if "model" in d:
        last = d["tail"][-1] if d["tail"] else []
        print(f"req {d['i']} {d['agent']} s{d['step']} +{d['t'] - t0:.1f}s..+{d['t_end'] - t0:.1f}s aborted={d['aborted']} last={json.dumps(last)[:160]}")
EOF
printf 'results: %s\n' "$R"
