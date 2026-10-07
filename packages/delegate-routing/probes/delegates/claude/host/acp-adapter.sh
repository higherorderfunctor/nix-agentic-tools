#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# usage: acp-adapter.sh [variant...]   — builds nixpkgs' claude-agent-acp (unfree) from this
# flake's own nixpkgs input and runs acp-adapter.py against the loopback mock.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../common/pin.sh
source "$here/../../common/pin.sh"
root="$(probe_repo_root)"
export CLAUDE_BIN="${CLAUDE_BIN:-$(probe_pkg claude-code)/bin/claude}"
adapter="$(NIXPKGS_ALLOW_UNFREE=1 nix build --impure --no-link --print-out-paths --inputs-from "$root" 'nixpkgs#claude-agent-acp')/bin/claude-agent-acp"
exec python3 -I "$here/acp-adapter.py" "$adapter" "$@"
