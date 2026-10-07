#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# usage: realtime.sh [port] [rtport]
# codex:P6.realtime — what a Realtime (voice) session sends at startup, OFFLINE. run.sh drives the
# realtime-context probe (one root turn, then thread/realtime/start over the websocket transport)
# against fp.py, while rtws.py stands in for the Realtime endpoint and logs every client frame.
# Prints each frame's type and which sentinels it carries: CFG-DEV-4000 (config
# developer_instructions), GLOBAL-AGENTS-4006 ($CODEX_HOME/AGENTS.md), RT-TURN-7701 (the thread's
# user turn), RT ROOT DONE 7702 (its assistant reply). The startup context lists the user's home
# tree two levels deep, so the run gets an empty scratch HOME (resolved builds come first).
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../common/pin.sh
source "$D/../common/pin.sh"
port="${1:-19488}"
export RTPORT="${2:-19489}"
CODEX_WORK="${CODEX_WORK:-$(probe_workdir codex)}"
export CODEX_WORK
rt="$CODEX_WORK/rt-realtime-context"
rm -rf "$rt" "$CODEX_WORK/rt-home"
mkdir -p "$CODEX_WORK/rt-home/PROBE-HOME-7703"
CODEX_PKG="${CODEX_PKG:-$(probe_pkg chatgpt-codex)}"
export CODEX_PKG
if [[ ! -f $CODEX_WORK/models_cache.json ]]; then
  python3 "$D/mkcache.py" "$(probe_pkg chatgpt-codex.src)" "$CODEX_WORK/models_cache.json"
fi
python3 "$D/rtws.py" "$RTPORT" "$rt" &
ws=$!
trap 'kill "$ws" 2>/dev/null || :' EXIT
sleep 0.3
HOME="$CODEX_WORK/rt-home" "$D/run.sh" realtime-context "$port"
python3 - "$rt/rt.jsonl" <<'PY'
import json, sys
SENT = ["CFG-DEV-4000", "GLOBAL-AGENTS-4006", "RT-TURN-7701", "RT ROOT DONE 7702", "PROBE-HOME-7703", "<startup_context>"]
for line in open(sys.argv[1]):
    rec = json.loads(line)
    if "path" in rec:
        print(f"connect {rec['path'].split('?')[0]}")
        continue
    frame = rec["frame"]
    text = json.dumps(frame)
    hits = " ".join(s for s in SENT if s in text) or "-"
    print(f"frame {frame.get('type')} len={len(text)} carries: {hits}")
PY
printf 'frames: %s\n' "$rt/rt.jsonl"
