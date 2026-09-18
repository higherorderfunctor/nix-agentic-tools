#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
for name in "${!DEVENV_@}" "${!DIRENV_@}"; do
  unset "$name"
done
unset SCRIBE_ROOT
source=$(nix build ../..#strictdoc-toolchain-source --max-jobs 1 --no-link --print-out-paths)
rm -rf -- .toolchain
cp -R -- "$source" .toolchain
chmod -R u+w .toolchain
devenv update library
