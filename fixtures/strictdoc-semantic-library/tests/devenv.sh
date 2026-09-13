#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

# Enter this native project without retaining another project's root variables.
for fixture_env_name in ${!DEVENV_@} ${!DIRENV_@}; do
  unset "$fixture_env_name"
done
unset SCRIBE_ROOT
cd "$(dirname "${BASH_SOURCE[0]}")/.."
exec devenv "$@"
