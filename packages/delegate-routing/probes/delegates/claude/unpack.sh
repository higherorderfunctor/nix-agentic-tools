#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# usage: unpack.sh <dir>   — unpacks the pinned claude binary's Bun module graph into <dir>
# with the repository's own extractor. The grep/AST probes read chunk-*.js from <dir>;
# chunk names are content hashes, so they match the report for the same pin.
dest="${1:?usage: unpack.sh <dir>}"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../common/pin.sh
source "$(dirname "${BASH_SOURCE[0]}")/../common/pin.sh"
root="$(probe_repo_root)"
binary="${CLAUDE_BIN:-$(probe_pkg claude-code)/bin/claude}"
python3 "$root/packages/claude-code/extract/bununpack.py" "$binary" "$dest" >&2
printf '%s\n' "$dest"
