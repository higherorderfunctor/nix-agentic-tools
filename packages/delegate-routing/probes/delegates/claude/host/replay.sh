#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# usage: replay.sh   — captures --version, sha256 and help output of the pinned claude
# into <work>/captures (work = $PROBE_OUT/claude-host or a fresh temp dir).
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../common/pin.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common/pin.sh"
binary="${CLAUDE_BIN:-$(probe_pkg claude-code)/bin/claude}"
out="$(probe_workdir claude-host)/captures"
mkdir -p "$out"
printf '%s\n' '## binary' >"$out/pinned-cli.txt"
"$binary" --version >>"$out/pinned-cli.txt"
sha256sum "$binary" >>"$out/pinned-cli.txt"
for pair in 'root --help' 'mcp mcp --help' 'mcp-serve mcp serve --help' 'agents agents --help' 'attach attach --help' 'stop stop --help' 'logs logs --help' 'rm rm --help'; do
  name="${pair%% *}"
  args="${pair#* }"
  # Intentional word splitting converts the fixed command labels above to argv.
  # shellcheck disable=SC2086
  "$binary" $args >"$out/$name.txt"
done
printf 'captures: %s\n' "$out"
