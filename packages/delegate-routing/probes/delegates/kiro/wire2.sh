#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# usage: [KIRO_BASE_HOME=<dir>] [T=secs] [SETTINGS='{cli.json keys}'] [CASE_ENV="K=V ..."] wire2.sh <case> -- <kiro-cli-chat args...>
# Pinned native kiro-cli-chat in an empty network namespace (unshare -rn, loopback only); all four service
# endpoints point at capserver2.py on 127.0.0.1:18765, which answers ListAvailableModels with two fixture
# models and GenerateAssistantResponse from cases/<case>/rules.json (else cases/x.rules.json).
# When cases/<case>/script.json exists, acpctl.py drives the process over ACP stdio with it.
# KIRO_BASE_HOME optionally supplies a fixture HOME; otherwise fixture_home.py creates a fake login.
# Writes <work>/<case>/run/{wire.jsonl,out.txt,acp.log,acp.err,chat.log,home,ws};
# work = $PROBE_OUT/kiro or a fresh temp dir. Binary: pinned kiro-cli unwrapped (KIRO_PKG overrides).
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../common/pin.sh
source "$S/../common/pin.sh"
name="${1:?usage: wire2.sh <case> -- <args>}"
shift
[[ ${1:-} == -- ]] && shift
U="${KIRO_PKG:-$(probe_pkg kiro-cli.unwrapped)}/bin"
C="$S/cases/$name"
R="$(probe_workdir kiro)/$name/run"
rm -rf "$R"
mkdir -p "$R/ws/p" "$R/ws/.kiro/agents"
if [[ -n ${KIRO_BASE_HOME:-} ]]; then
  cp -r "$KIRO_BASE_HOME" "$R/home"
else
  python3 "$S/fixture_home.py" "$R/home" >/dev/null
fi
chmod -R u+w "$R/home"
cp -r "$S/home-overlay/." "$R/home/"
if [[ -d $C/home-overlay ]]; then cp -r "$C/home-overlay/." "$R/home/"; fi
cp -r "$S/ws/." "$R/ws/"
if [[ -d $C/ws ]]; then cp -r "$C/ws/." "$R/ws/"; fi
rules="$S/cases/x.rules.json"
if [[ -f $C/rules.json ]]; then rules="$C/rules.json"; fi
sed "s|@RUN@|$R|g" "$rules" >"$R/rules.json"
driver=""
if [[ -f $C/script.json ]]; then driver="python3 $S/acpctl.py $C/script.json"; fi
python3 - "$R/home/.kiro/settings/cli.json" "${SETTINGS:-}" "$S" <<'PY'
import json, os, sys
sys.path.insert(0, sys.argv[3])
from fixture_home import service_settings
p = sys.argv[1]
d = json.load(open(p)) if os.path.exists(p) else {}
if sys.argv[2]:
    d.update(json.loads(sys.argv[2]))
d.update(service_settings())
os.makedirs(os.path.dirname(p), exist_ok=True)
json.dump(d, open(p, "w"))
PY
cd "$R/ws"
rc=0
# The inner script is single-quoted on purpose: it runs in the new namespace with values passed as env.
# shellcheck disable=SC2016
R="$R" S="$S" U="$U" DRIVER="$driver" CASE_ENV="${CASE_ENV:-}" T="${T:-60}" unshare -rn bash -c '
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
ip link set lo up
RULES="$R/rules.json" python3 "$S/capserver2.py" 18765 "$R/wire.jsonl" &
sp=$!
sleep 0.5
read -r -a case_env <<<"$CASE_ENV"
read -r -a driver <<<"$DRIVER"
r=0
env -i PATH="$U:/usr/bin:/bin" HOME="$R/home" CFFIXED_USER_HOME="$R/home" XDG_CONFIG_HOME="$R/home/.config" \
  XDG_CACHE_HOME="$R/home/.cache" XDG_DATA_HOME="$R/home/.local/share" TERM=dumb KIRO_DISABLE_TELEMETRY=1 \
  ACP_LOG="$R/acp.log" ACP_STDERR="$R/acp.err" KIRO_LOG_LEVEL=debug KIRO_CHAT_LOG_FILE="$R/chat.log" "${case_env[@]}" \
  timeout "$T" "${driver[@]}" "$U/kiro-cli-chat" "$@" >"$R/out.txt" 2>&1 || r=$?
kill "$sp"
exit "$r"' _ "$@" || rc=$?
printf 'rc=%s run=%s\n' "$rc" "$R"
