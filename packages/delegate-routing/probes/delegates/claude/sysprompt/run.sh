#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# usage: run.sh <work> <case-name> <plan.json|-> -- <claude args...>
# One system-prompt capture: pinned claude against mock.py (records every request body as
# <work>/<case>/req-NNN.json). cwd = <work>/cwd (a git copy of ./cwd); CLAUDE_CONFIG_DIR =
# <work>/config, shared by the cases of one <work> so resume cases see earlier sessions.
# Optional env: STDIN_FILE (piped to claude), CLAUDE_BIN (skip the nix build).
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work=$1 name=$2 plan=$3
shift 4
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../common/pin.sh
source "$here/../../common/pin.sh"
binary="${CLAUDE_BIN:-$(probe_pkg claude-code)/bin/claude}"
if [[ ! -d $work/cwd ]]; then
  mkdir -p "$work/cwd" "$work/config"
  cp -r "$here/cwd/." "$work/cwd/"
  git -C "$work/cwd" init -q -b main
fi
out=$work/$name
rm -rf "$out"
mkdir -p "$out"
port=$((18000 + RANDOM % 1000))
if [[ $plan != - ]]; then export MOCK_PLAN=$plan; else unset MOCK_PLAN; fi
MOCK_PORT=$port MOCK_DIR=$out python3 "$here/mock.py" &
mpid=$!
trap 'kill "$mpid" 2>/dev/null || :' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  (echo >"/dev/tcp/127.0.0.1/$port") 2>/dev/null && break
  sleep 0.2
done
printf '%q ' claude "$@" >"$out/cmd"
cd "$work/cwd"
rc=0
CLAUDE_CONFIG_DIR=$work/config ANTHROPIC_BASE_URL=http://127.0.0.1:$port ANTHROPIC_API_KEY=mock-offline-not-a-key \
  DISABLE_TELEMETRY=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  timeout 120 "$binary" "$@" >"$out/stdout" 2>"$out/stderr" <"${STDIN_FILE:-/dev/null}" || rc=$?
echo "rc=$rc" >>"$out/stderr"
find "$out" -maxdepth 1 -name 'req-*' | wc -l | sed 's/^/requests=/'
