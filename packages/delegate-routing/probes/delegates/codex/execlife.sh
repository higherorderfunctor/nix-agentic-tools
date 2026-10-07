#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# usage: execlife.sh <probe> <port> [SIGNAL <delay-secs>]
# codex:L1 — `codex exec` root end and signal cascade, OFFLINE (fake provider, fresh CODEX_HOME).
# Runs `codex --no-daemon exec --json` on probes/<probe>/ (config.toml + scenario.json, as run.sh).
# With SIGNAL, sends it to the exec PID only (what a host's kill(2) does; a terminal ^C would hit
# the whole process group) after <delay-secs>. Prints exit code and seconds, every fake-provider
# request with aborted=true when codex hung up mid-stream, and how many background processes the
# child started (`sleep 300; echo DMUMARK`) are still alive 3 s after exec exits. Survivors are then killed.
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../common/pin.sh
source "$D/../common/pin.sh"
name="${1:?usage: execlife.sh <probe> <port> [SIGNAL delay]}"
port="${2:?port}"
sig="${3:-}"
delay="${4:-8}"
work="${CODEX_WORK:-$(probe_workdir codex)}"
pkg="${CODEX_PKG:-$(probe_pkg chatgpt-codex)}"
if [[ ! -f $work/models_cache.json ]]; then
  python3 "$D/mkcache.py" "$(probe_pkg chatgpt-codex.src)" "$work/models_cache.json"
fi
P="$D/probes/$name"
R="$work/results/$name${sig:+-$sig}"
H="$R/home"
rm -rf "$R"
mkdir -p "$R/wire" "$H" "$work/plain"
sed -e "s|@PORT@|$port|g" "$P/config.toml" >"$H/config.toml"
cp "$work/models_cache.json" "$H/models_cache.json"
# The shell codex starts for the child's command ends its argv with the marker; matching the line END
# keeps any shell whose own command text merely mentions the marker (e.g. the caller's) out of it.
marks() { ps -eo pid=,args= | awk '/-c sleep 300; echo DMU[M]ARK$/ { print $1 }'; }
python3 "$D/fp.py" "$port" "$R/wire" "$P/scenario.json" &
fp=$!
# reap: kill each survivor's process group (sandbox wrapper, shell, sleep), never this script's own.
reap() {
  local m g own
  own="$(ps -o pgid= -p $$ | tr -d ' ')"
  for m in $(marks); do
    g="$(ps -o pgid= -p "$m" | tr -d ' ')" || continue
    if [[ -n $g && $g != "$own" ]]; then kill -- "-$g" 2>/dev/null || :; else kill "$m" 2>/dev/null || :; fi
  done
}
trap 'kill "$fp" 2>/dev/null || :; reap' EXIT
sleep 0.5
start=$(date +%s.%N)
(cd "$work/plain" && exec env CODEX_HOME="$H" FAKE_KEY=x "$pkg/bin/codex" --no-daemon exec --json --skip-git-repo-check GO \
  </dev/null >"$R/events.jsonl" 2>"$R/stderr.txt") &
cx=$!
if [[ -n $sig ]]; then
  sleep "$delay"
  printf 'before %s: DMUMARK alive=%s\n' "$sig" "$(marks | wc -l)"
  kill -s "$sig" "$cx"
fi
rc=0
wait "$cx" || rc=$?
end=$(date +%s.%N)
sleep 3
printf 'exit=%s secs=%.1f\n' "$rc" "$(echo "$end - $start" | bc)"
printf 'after exit +3s: DMUMARK alive=%s\n' "$(marks | wc -l)"
for m in $(marks); do ps -o pid=,ppid=,pgid=,args= -p "$m" | cut -c1-120 | sed 's/^/  survivor /'; done
python3 - "$R/wire/log.jsonl" "$start" <<'EOF'
import json, sys
t0 = float(sys.argv[2])
for line in open(sys.argv[1]):
    d = json.loads(line)
    if "model" in d:
        print(f"req {d['i']} {d['agent']} s{d['step']} start=+{d['t'] - t0:.1f}s end=+{d['t_end'] - t0:.1f}s aborted={d['aborted']}")
EOF
python3 -c 'import json,sys; print("events:", " ".join(json.loads(l).get("type","?") for l in open(sys.argv[1]) if l.strip()))' "$R/events.jsonl"
printf 'results: %s\n' "$R"
