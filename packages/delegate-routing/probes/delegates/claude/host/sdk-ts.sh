#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# usage: sdk-ts.sh [variant...]   — what the TS Agent SDK sends when a host imports it directly.
# Builds nixpkgs' claude-agent-acp (unfree) and nodejs from this flake's own nixpkgs input and
# runs sdk-ts.mjs with the SDK bundled inside the adapter (sdk.mjs) against the loopback mock.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../common/pin.sh
source "$here/../../common/pin.sh"
root="$(probe_repo_root)"
export CLAUDE_BIN="${CLAUDE_BIN:-$(probe_pkg claude-code)/bin/claude}"
adapter="$(NIXPKGS_ALLOW_UNFREE=1 nix build --impure --no-link --print-out-paths --inputs-from "$root" 'nixpkgs#claude-agent-acp')"
node="$(nix build --no-link --print-out-paths --inputs-from "$root" 'nixpkgs#nodejs')/bin/node"
sdk="$adapter/lib/node_modules/@agentclientprotocol/claude-agent-acp/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs"
exec "$node" "$here/sdk-ts.mjs" "$sdk" "$@"
