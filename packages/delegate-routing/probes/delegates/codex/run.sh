#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# usage: run.sh <probe-name> [port]   — replays one probe offline (fake provider, no account)
# Probe = $PROBE_DIR or probes/<probe-name>/ {config.toml, scenario.json, probe.json, extra/}.
# Writes <work>/results/<probe>/{wire,as,home}; work = $PROBE_OUT/codex or a fresh temp dir
# (export CODEX_WORK to reuse one across calls). Binary: the pinned chatgpt-codex (CODEX_PKG overrides).
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../common/pin.sh
source "$D/../common/pin.sh"
name="${1:?usage: run.sh <probe-name> [port]}"
port="${2:-18990}"
work="${CODEX_WORK:-$(probe_workdir codex)}"
pkg="${CODEX_PKG:-$(probe_pkg chatgpt-codex)}"
export CODEX_BIN="$pkg/bin/codex"
if [[ ! -f $work/models_cache.json ]]; then
  python3 "$D/mkcache.py" "$(probe_pkg chatgpt-codex.src)" "$work/models_cache.json"
fi
P="${PROBE_DIR:-$D/probes/$name}"
R="$work/results/$name"
H="$R/home"
rm -rf "$R"
mkdir -p "$R/wire" "$H" "$work/plain"
sed -e "s|@PORT@|$port|g" -e "s|@D@|$D|g" "$P/config.toml" >"$H/config.toml"
cp "$work/models_cache.json" "$H/models_cache.json"
if [[ -d $P/extra ]]; then cp -r "$P/extra/." "$H/"; fi
shopt -s globstar nullglob
for f in "$H"/**/*.toml; do sed -i -e "s|@D@|$D|g" -e "s|@H@|$H|g" "$f"; done
shopt -u globstar nullglob
python3 "$D/fp.py" "$port" "$R/wire" "$P/scenario.json" &
fp=$!
trap 'kill "$fp" 2>/dev/null || :' EXIT
sleep 0.5
python3 "$D/asclient.py" "$H" "$R/as" "$work/plain" "$P/probe.json"
rm -rf "$H/.tmp" "$H/skills" # bulky plugin/skill caches the app-server writes; not evidence
printf 'results: %s\n' "$R"
