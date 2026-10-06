#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# usage: replay.sh limit|options
#   limit    one explicit sonnet/low node, then default nodes until node 1,001 → WorkflowAgentCapError
#   options  four parallel() nodes with CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS=2; explicit node sonnet/low
# Pinned claude -p against a loopback fake Messages API (mock_api.py); fake key, no upstream.
# Writes <work>/<mode>-replay/{requests.jsonl,stdout,stderr,status}; work = $PROBE_OUT/claude-workflow or a temp dir.
mode="${1:?usage: replay.sh limit|options}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../common/pin.sh
source "$here/../../common/pin.sh"
binary="${CLAUDE_BIN:-$(probe_pkg claude-code)/bin/claude}"
case "$mode" in
limit) port=19371 limit=300 script= ;;
options) port=19372 limit=60 script="$here/options.workflow" ;;
*)
  printf 'unknown mode: %s\n' "$mode" >&2
  exit 2
  ;;
esac
out="$(probe_workdir claude-workflow)/$mode-replay"
rm -rf "$out"
mkdir -p "$out/config" "$out/cwd"
MOCK_PORT="$port" MOCK_OUT="$out" MOCK_SCRIPT="$script" python3 "$here/mock_api.py" &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || :' EXIT
for _ in {1..50}; do
  if (echo >"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then break; fi
  sleep 0.1
done
cd "$out/cwd"
status=0
printf 'WF_ROOT_RUN\n' | CLAUDE_CONFIG_DIR="$out/config" ANTHROPIC_BASE_URL="http://127.0.0.1:$port" \
  ANTHROPIC_API_KEY=mock-offline-not-a-key DISABLE_TELEMETRY=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  CLAUDE_CODE_WORKFLOWS=1 CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS=2 \
  timeout "$limit" "$binary" -p --no-session-persistence --setting-sources "" --settings '{"enableWorkflows":true}' \
  --strict-mcp-config --mcp-config '{"mcpServers":{}}' --tools Workflow --allowedTools Workflow \
  --permission-mode bypassPermissions --allow-dangerously-skip-permissions --model haiku \
  >"$out/stdout" 2>"$out/stderr" || status=$?
printf 'claude_exit=%s\n' "$status" >"$out/status"
printf 'out: %s\n' "$out"
