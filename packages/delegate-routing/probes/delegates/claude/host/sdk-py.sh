#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# usage: sdk-py.sh [variant...]   — what the official Python Agent SDK sends by default.
# Builds python3.withPackages([claude-agent-sdk]) from this flake's own nixpkgs input (no
# network beyond the binary cache) and runs sdk-py.py against the loopback mock.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../common/pin.sh
source "$here/../../common/pin.sh"
root="$(probe_repo_root)"
export CLAUDE_BIN="${CLAUDE_BIN:-$(probe_pkg claude-code)/bin/claude}"
python="$(nix build --no-link --print-out-paths --impure --expr \
  "let p = (builtins.getFlake \"$root\").inputs.nixpkgs.legacyPackages.\${builtins.currentSystem}; in p.python3.withPackages (ps: [ ps.claude-agent-sdk ])")/bin/python3"
exec "$python" -I "$here/sdk-py.py" "$@"
