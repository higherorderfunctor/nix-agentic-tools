#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# usage: wire.sh <wireA|wireB|wireC|wireBase|wireL1|wireL2> [port]
# codex:R4 — captures one system-prompt wire run at the pin: scripted.py records every
# POST /v1/responses body; `codex debug app-server send-message-v2 TRIGGER` drives one root turn.
# Writes <work>/<case>/req*.json and prints analyze.py's sentinel summary.
# work = $PROBE_OUT/codex-sysprompt or a fresh temp dir. Binary: pinned chatgpt-codex (CODEX_PKG overrides).
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../common/pin.sh
source "$D/../../common/pin.sh"
name="${1:?usage: wire.sh <case> [port]}"
port="${2:-18777}"
case "$name" in
wireA | wireB) spawns=spawnsA.json ;;
wireC) spawns=spawnsC.json ;;
wireBase) spawns=spawnsBase.json ;;
wireL1 | wireL2) spawns=spawnsR.json ;;
*)
  printf 'unknown case: %s\n' "$name" >&2
  exit 2
  ;;
esac
work="$(probe_workdir codex-sysprompt)"
pkg="${CODEX_PKG:-$(probe_pkg chatgpt-codex)}"
if [[ ! -f $work/models_cache.json ]]; then
  python3 "$D/../mkcache.py" "$(probe_pkg chatgpt-codex.src)" "$work/models_cache.json"
fi
out="$work/$name"
home="$work/home-$name"
rm -rf "$out" "$home"
mkdir -p "$out" "$home" "$work/plain"
sed -e "s|@PORT@|$port|g" -e "s|@D@|$D|g" "$D/homes/$name.toml" >"$home/config.toml"
cp "$work/models_cache.json" "$home/models_cache.json"
python3 "$D/scripted.py" "$port" "$out" "$D/$spawns" &
fp=$!
trap 'kill "$fp" 2>/dev/null || :' EXIT
sleep 0.5
(cd "$work/plain" && FAKE_KEY=x CODEX_HOME="$home" timeout 120 "$pkg/bin/codex" --no-daemon debug app-server send-message-v2 "TRIGGER") >"$out/client.log" 2>&1 || :
python3 "$D/analyze.py" "$out"
printf 'out: %s\n' "$out"
