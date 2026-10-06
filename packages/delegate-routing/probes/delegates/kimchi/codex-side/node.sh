#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# usage: node.sh <script.cjs> [args...]   — runs one codex-side AST/VM script against the pinned sources.
# Exports TYPESCRIPT_JS (nixpkgs typescript_5 from this flake's inputs), KIMCHI_SRC (kimchi.src),
# PI_SRC (kimchi.extractionSources.pi) and KIMCHI_WORKFLOWS_SRC (kimchi-workflows.src); scripts that
# write JSON write it to the current directory.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../common/pin.sh
source "$here/../../common/pin.sh"
script="${1:?usage: node.sh <script.cjs> [args...]}"
shift
root="$(probe_repo_root)"
TYPESCRIPT_JS="$(nix build --no-link --print-out-paths --inputs-from "$root" nixpkgs#typescript_5)/lib/node_modules/typescript/lib/typescript.js"
KIMCHI_SRC="$(probe_pkg kimchi.src)"
PI_SRC="$(probe_pkg kimchi.extractionSources.pi)"
KIMCHI_WORKFLOWS_SRC="$(probe_pkg kimchi-workflows.src)"
export TYPESCRIPT_JS KIMCHI_SRC PI_SRC KIMCHI_WORKFLOWS_SRC
exec node "$script" "$@"
