#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# usage: tui/tuiwire.sh [base-port]
# codex:T1 — TUI wire parity and config.toml reload, OFFLINE (fake provider, fresh CODEX_HOMEs).
# Surfaces, one home each, same config (tui/config.toml) and same trusted cwd:
#   tui-embedded  `codex --no-daemon` under tmux
#   tui-daemon    `codex` under tmux: starts the shared app-server daemon inside that CODEX_HOME
#   app-server    `codex --no-daemon app-server` driven by asclient.py
#   tui-termviz   `codex --no-daemon -c features.terminal_visualization_instructions=true`
#   exec          `codex --no-daemon exec`
# Both TUI runs send TUI-PROMPT-ONE, rewrite developer_instructions in config.toml
# (CFG-DEV-A-6001 -> CFG-DEV-B-6002), send TUI-PROMPT-TWO, then run /recap. The TUI's title and
# recap side turns are captured alongside the main turns. Prints where each sentinel landed
# and parity.py against the tui-embedded first request. Needs tmux. The daemon is stopped and its
# updater loop killed at the end; every process stays inside the scratch homes.
D="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$D/tui"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../common/pin.sh
source "$D/../common/pin.sh"
base="${1:-19130}"
work="$(probe_workdir codex-tui)"
pkg="${CODEX_PKG:-$(probe_pkg chatgpt-codex)}"
codex="$pkg/bin/codex"
if [[ ! -f $work/models_cache.json ]]; then
  python3 "$D/mkcache.py" "$(probe_pkg chatgpt-codex.src)" "$work/models_cache.json"
fi
plain="$work/plain"
mkdir -p "$plain"
pids=()
# stop_daemon <home>: stop the shared daemon a TUI started in <home>. `daemon stop` leaves the
# updater loop running, so kill that too (only when its argv points into <home>).
stop_daemon() {
  local h="$1" up
  [[ -d $h/app-server-daemon ]] || return 0
  printf 'daemon %s: %s\n' "$h" "$(CODEX_HOME="$h" timeout 60 "$codex" app-server daemon stop 2>&1 | tail -n1)"
  up="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$h/app-server-daemon/daemon-updater.pid" 2>/dev/null || :)"
  if [[ -n $up ]] && tr '\0' '\n' <"/proc/$up/cmdline" 2>/dev/null | grep -qF "$h/"; then kill "$up" || :; fi
}
cleanup() {
  local p
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null || :; done
  tmux -L dmu-tui kill-server 2>/dev/null || :
  stop_daemon "$work/tui-daemon/home" >/dev/null 2>&1 || :
}
trap cleanup EXIT

# setup <surface> <port>: fresh home + wire dir + fake provider
setup() {
  local s="$1" port="$2"
  rm -rf "${work:?}/$s"
  mkdir -p "$work/$s/home" "$work/$s/wire"
  sed -e "s|@PORT@|$port|g" -e "s|@PLAIN@|$plain|g" "$T/config.toml" >"$work/$s/home/config.toml"
  cp "$work/models_cache.json" "$work/$s/home/models_cache.json"
  python3 "$D/fp.py" "$port" "$work/$s/wire" "$T/scenario.json" &
  pids+=("$!")
  sleep 0.5
}

# wait_pane <surface> <text> [secs]: poll the tmux pane until it shows <text>
wait_pane() {
  local s="$1" text="$2" n="${3:-30}"
  while ((n-- > 0)); do
    if tmux -L dmu-tui capture-pane -p -t "$s" | grep -qF -- "$text"; then return 0; fi
    sleep 1
  done
  printf 'timeout waiting for %q in %s\n' "$text" "$s" >&2
  tmux -L dmu-tui capture-pane -p -t "$s" | grep -v '^\s*$' | tail -15 >&2
  false
}

# submit <surface> <text> <expect>: type <text>, press Enter, wait for <expect> to appear after it.
# A daemon-backed TUI can draw its composer before the connection is ready and drop that Enter,
# so Enter is re-sent up to three times.
submit() {
  local s="$1" text="$2" expect="$3" try
  tmux -L dmu-tui send-keys -t "$s" "$text"
  for try in 1 2 3; do
    sleep 0.5
    tmux -L dmu-tui send-keys -t "$s" Enter
    local n=10
    while ((n-- > 0)); do
      if tmux -L dmu-tui capture-pane -p -t "$s" | grep -A8 -F -- "$text" | grep -qF -- "$expect"; then return 0; fi
      sleep 1
    done
    printf '%s: no reply to %s after Enter #%s\n' "$s" "$text" "$try" >&2
  done
  wait_pane "$s" "$expect" 1
}

# tui <surface> <port> [codex args...]
tui() {
  local s="$1" port="$2"
  shift 2
  setup "$s" "$port"
  local h="$work/$s/home"
  tmux -L dmu-tui new-session -d -s "$s" -x 200 -y 50 -c "$plain" \
    env CODEX_HOME="$h" FAKE_KEY=x "$codex" "$@"
  wait_pane "$s" "Ask Codex to do anything" 40
  submit "$s" "TUI-PROMPT-ONE" "TUI REPLY ONE"
  sleep 3 # let the title side turn land before the edit
  sed -i 's/CFG-DEV-A-6001/CFG-DEV-B-6002/' "$h/config.toml"
  sleep 2
  submit "$s" "TUI-PROMPT-TWO" "TUI REPLY"
  sleep 6 # the second title side turn
  tmux -L dmu-tui send-keys -t "$s" "/recap"
  sleep 1
  tmux -L dmu-tui send-keys -t "$s" Enter
  sleep 6                                                # manual recap side turn (the fake reply is not JSON, so the TUI reports a failed recap)
  tmux -L dmu-tui send-keys -t "$s" C-c 2>/dev/null || : # the first C-c may already end the session
  sleep 1
  tmux -L dmu-tui send-keys -t "$s" C-c 2>/dev/null || : # the first C-c may already end the session
  sleep 1
  tmux -L dmu-tui kill-session -t "$s" 2>/dev/null || :
  stop_daemon "$h"
}

tui tui-embedded "$base" --no-daemon
tui tui-daemon "$((base + 1))"
tui tui-termviz "$((base + 4))" --no-daemon -c features.terminal_visualization_instructions=true

setup app-server "$((base + 2))"
CODEX_BIN="$codex" python3 "$D/asclient.py" "$work/app-server/home" "$work/app-server/as" "$plain" "$T/probe.json"

setup exec "$((base + 3))"
(cd "$plain" && CODEX_HOME="$work/exec/home" FAKE_KEY=x timeout 60 "$codex" --no-daemon exec --skip-git-repo-check "TUI-PROMPT-ONE" </dev/null >"$work/exec/out.txt" 2>&1) || :

for s in tui-embedded tui-daemon tui-termviz app-server exec; do
  printf '== %s\n' "$s"
  python3 "$D/sentinels.py" "$work/$s/wire" CFG-DEV-A-6001 CFG-DEV-B-6002 TUI-PROMPT-ONE TUI-PROMPT-TWO "task title" "catch-up for a user returning" "This surface is a terminal"
done
printf '== parity (ref: tui-embedded first request)\n'
python3 "$T/parity.py" "$work/tui-embedded/wire/req00-root-s0.json" \
  "$work/tui-daemon/wire/req00-root-s0.json" "$work/app-server/wire/req00-root-s0.json" "$work/exec/wire/req00-root-s0.json"
printf 'work: %s\n' "$work"
