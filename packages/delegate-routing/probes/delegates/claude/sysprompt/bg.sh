#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# usage: bg.sh   — does a `claude --bg` session keep the CLI prompt flags?
# Starts the mock, launches `claude --bg` with a main and a sub-agent append in a trusted
# scratch config (fake key, loopback base URL), waits for the background session's first
# model request, stops every background session and prints where each sentinel landed.
# Output: <work> = $PROBE_OUT/claude-bg or a fresh temp dir.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../common/pin.sh
source "$here/../../common/pin.sh"
binary="${CLAUDE_BIN:-$(probe_pkg claude-code)/bin/claude}"
work="$(probe_workdir claude-bg)"
rm -rf "${work:?}/out" "${work:?}/config" "${work:?}/cwd" "${work:?}/home"
mkdir -p "$work/out" "$work/config" "$work/home"
cp -r "$here/cwd" "$work/cwd"
git -C "$work/cwd" init -q -b main
# trust the fixture and pre-approve the fake key (last 20 characters), as the TUI would ask for both
printf '{"hasCompletedOnboarding":true,"customApiKeyResponses":{"approved":["%s"],"rejected":[]},"projects":{"%s":{"hasCompletedProjectOnboarding":true,"hasTrustDialogAccepted":true}}}\n' \
  "ck-offline-not-a-key" "$work/cwd" >"$work/config/.claude.json"
port=$((19000 + RANDOM % 1000))
export CLAUDE_CONFIG_DIR=$work/config HOME=$work/home ANTHROPIC_BASE_URL=http://127.0.0.1:$port \
  ANTHROPIC_API_KEY=mock-offline-not-a-key DISABLE_TELEMETRY=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
MOCK_PORT=$port MOCK_DIR=$work/out python3 "$here/mock.py" &
mpid=$!
cleanup() {
  local id
  id="$(sed -n 's/^backgrounded · \([0-9a-f]*\).*/\1/p' "$work/launch.stdout" 2>/dev/null || :)"
  if [[ -n $id ]]; then
    (cd "$work/cwd" && timeout 30 "$binary" stop "$id" >/dev/null 2>&1) || :
  fi
  kill "$mpid" 2>/dev/null || :
}
trap cleanup EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  (echo >"/dev/tcp/127.0.0.1/$port") 2>/dev/null && break
  sleep 0.2
done
cd "$work/cwd"
rc=0
timeout 60 "$binary" --bg --model haiku \
  --append-system-prompt "Inline append sentinel: APPINLINE-1313." \
  --append-subagent-system-prompt "Subagent append: SUBAPP-1414." hi \
  >"$work/launch.stdout" 2>"$work/launch.stderr" || rc=$?
printf 'launch rc=%s\n' "$rc"
for _ in $(seq 1 60); do
  if compgen -G "$work/out/req-*.json" >/dev/null; then break; fi
  sleep 1
done
sleep 3
python3 "$here/an.py" "$work/out"
printf 'work: %s\n' "$work"
