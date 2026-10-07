#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# usage: memories.sh [port] [probe]   (probe: probes/<probe>/, default memories)
# codex:M1 — memory pipeline side turns, OFFLINE (fake provider, one fresh CODEX_HOME).
# Session A (seed.json) leaves a rollout; its state-DB row is then backdated 2 h and marked
# source=cli, because Phase 1 only claims interactive (cli/vscode) rollouts idle for at least
# memories.min_rollout_idle_hours (clamped to >= 1). Session B (probe.json) starts the startup
# pipeline: Phase 1 extraction (structured JSON request) and Phase 2 consolidation (internal agent).
# Prints each request's model and where the sentinels landed.
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../common/pin.sh
source "$D/../common/pin.sh"
port="${1:-19140}"
name="${2:-memories}"
P="$D/probes/$name"
work="$(probe_workdir "codex-$name")"
pkg="${CODEX_PKG:-$(probe_pkg chatgpt-codex)}"
export CODEX_BIN="$pkg/bin/codex"
if [[ ! -f $work/models_cache.json ]]; then
  python3 "$D/mkcache.py" "$(probe_pkg chatgpt-codex.src)" "$work/models_cache.json"
fi
H="$work/home"
rm -rf "$H" "$work/wire" "$work/asA" "$work/asB"
mkdir -p "$H" "$work/wire" "$work/plain"
sed -e "s|@PORT@|$port|g" "$P/config.toml" >"$H/config.toml"
cp "$work/models_cache.json" "$H/models_cache.json"
cp -rL "$P/extra/." "$H/"
# jobs <label>: memory job rows after a session. A failed job is not retried in-session; it waits
# for retry_at (retry_remaining counts down from 3).
jobs() {
  python3 - "$H" "$1" <<'EOF'
import glob, sqlite3, sys, time
dbs = glob.glob(f"{sys.argv[1]}/memories_*.sqlite")
rows = sqlite3.connect(dbs[0]).execute("SELECT kind, status, retry_remaining, retry_at, last_error FROM jobs ORDER BY kind").fetchall() if dbs else []
if not rows:
    print(f"job[{sys.argv[2]}] none")
for kind, status, left, retry_at, err in rows:
    wait = "-" if retry_at is None else f"+{retry_at - int(time.time())}s"
    print(f"job[{sys.argv[2]}] {kind} status={status} retry_remaining={left} retry_at={wait} last_error={(err or '-')[:120]!r}")
EOF
}
python3 "$D/fp.py" "$port" "$work/wire" "$P/scenario.json" &
fp=$!
trap 'kill "$fp" 2>/dev/null || :' EXIT
sleep 0.5
python3 "$D/asclient.py" "$H" "$work/asA" "$work/plain" "$P/seed.json"
jobs A
python3 - "$H/state_5.sqlite" <<'EOF'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
n = db.execute("UPDATE threads SET updated_at_ms = updated_at_ms - 7200000, source = 'cli'").rowcount
db.commit()
print(f"backdated {n} thread(s)")
EOF
python3 "$D/asclient.py" "$H" "$work/asB" "$work/plain" "$P/probe.json"
python3 - "$work/wire/log.jsonl" <<'EOF'
import json, sys
for line in open(sys.argv[1]):
    r = json.loads(line)
    if "model" not in r: continue
    last = (r["tail"][-1][2] if r["tail"] and len(r["tail"][-1]) > 2 else "")[:60].replace("\n", " ")
    print(f"#{r['i']:02d} {r['agent']:<6} model={r['model']} effort={r['effort']} tools={len(r['tools'])} last={last!r}")
EOF
python3 "$D/sentinels.py" "$work/wire" CFG-DEV-4000 GLOBAL-AGENTS-4006 MEMORY-SEED-7000 "Phase 1 (Single Rollout)" "Phase 2 (Consolidation)"
jobs B
printf 'work: %s\n' "$work"
