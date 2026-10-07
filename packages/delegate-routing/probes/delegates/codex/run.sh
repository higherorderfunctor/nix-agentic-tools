#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# usage: run.sh <probe-name> [port]   — replays one probe offline (fake provider, no account)
# Probe = $PROBE_DIR or probes/<probe-name>/ {config.toml, scenario.json, probe.json, probe2.json, extra/}.
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
sed -e "s|@PORT@|$port|g" -e "s|@RTPORT@|${RTPORT:-0}|g" -e "s|@D@|$D|g" "$P/config.toml" >"$H/config.toml"
cp "$work/models_cache.json" "$H/models_cache.json"
if [[ -d $P/extra ]]; then cp -rL "$P/extra/." "$H/"; fi # -L: probes may symlink shared fixtures
shopt -s globstar nullglob
for f in "$H"/**/*.toml; do sed -i -e "s|@D@|$D|g" -e "s|@H@|$H|g" "$f"; done
shopt -u globstar nullglob
python3 "$D/fp.py" "$port" "$R/wire" "$P/scenario.json" &
fp=$!
trap 'kill "$fp" 2>/dev/null || :' EXIT
sleep 0.5
# A probe's etc-codex/ is mounted at /etc/codex (requirements.toml, managed_config.toml) inside an
# unprivileged bwrap namespace: tmp-overlay over /etc, no root, the host /etc is untouched.
etc=()
if [[ -d $P/etc-codex ]]; then
  etc=(bwrap --dev-bind / / --overlay-src /etc --tmp-overlay /etc --ro-bind "$P/etc-codex" /etc/codex)
fi
"${etc[@]}" python3 "$D/asclient.py" "$H" "$R/as" "$work/plain" "$P/probe.json"
# probe2.json: a second app-server process on the same home and fake provider after the first exits
# (restart probes; its "resume": "as/thread_id" picks up the first process's root thread).
if [[ -f $P/probe2.json ]]; then
  "${etc[@]}" python3 "$D/asclient.py" "$H" "$R/as2" "$work/plain" "$P/probe2.json"
fi
rm -rf "$H/.tmp" "$H/skills" # bulky plugin/skill caches the app-server writes; not evidence
printf 'results: %s\n' "$R"
