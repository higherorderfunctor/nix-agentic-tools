#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# usage: help.sh   — claude:R0 + claude:R1 for the pinned codex:
#   R0  <work>/help/<sub>.txt for each subcommand's --help, and `codex features list`
#   R1  <work>/schema and <work>/schema-exp from `app-server generate-json-schema [--experimental]`
# work = $PROBE_OUT/codex-help or a fresh temp dir; CODEX_HOME is a fresh dir inside it.
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../common/pin.sh
source "$D/../common/pin.sh"
work="$(probe_workdir codex-help)"
codex="${CODEX_PKG:-$(probe_pkg chatgpt-codex)}/bin/codex"
export CODEX_HOME="$work/home"
mkdir -p "$work/help" "$CODEX_HOME"
for sub in root exec exec_resume exec_fork exec_review review agents queue app-server app-server_daemon \
  remote-control cloud cloud_exec exec-server mcp resume fork; do
  args=()
  if [[ $sub != root ]]; then IFS=_ read -r -a args <<<"$sub"; fi
  "$codex" --no-daemon "${args[@]}" --help >"$work/help/$sub.txt" 2>&1 || printf 'exit %s\n' "$?" >>"$work/help/$sub.txt"
done
"$codex" --no-daemon features list >"$work/help/features.txt" 2>&1
"$codex" --no-daemon app-server generate-json-schema --out "$work/schema"
"$codex" --no-daemon app-server generate-json-schema --experimental --out "$work/schema-exp"
printf 'work: %s\n' "$work"
