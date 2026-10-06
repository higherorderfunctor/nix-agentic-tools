#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# usage: help.sh   — codex:R1: --version, --help of root/chat/acp/settings/agent/crew/mcp/serve and the
# binary sha256 of the pinned kiro-cli-chat, into <work>/help (work = $PROBE_OUT/kiro-help or a temp dir).
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../common/pin.sh
source "$D/../../common/pin.sh"
U="${KIRO_PKG:-$(probe_pkg kiro-cli.unwrapped)}/bin"
out="$(probe_workdir kiro-help)/help"
mkdir -p "$out"
export HOME="$out/home"
"$U/kiro-cli-chat" --version >"$out/version.txt"
"$U/kiro-cli-chat" --help >"$out/root.txt"
for command in chat acp settings agent crew mcp serve; do
  "$U/kiro-cli-chat" "$command" --help >"$out/$command.txt" 2>&1
done
sha256sum "$U/.kiro-cli-chat-wrapped" >"$out/binary.sha256"
printf 'help: %s\n' "$out"
