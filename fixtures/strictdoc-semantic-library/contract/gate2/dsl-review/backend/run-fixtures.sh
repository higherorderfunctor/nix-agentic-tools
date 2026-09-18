#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

# Runs the conformance suite from any working directory. Extra arguments are
# passed through to unittest, so ./run-fixtures.sh -k visibility narrows the run
# to one family.
#
# The top level directory is the tests directory rather than the backend
# directory. Python 3.11 and later refuse a start directory that is not
# importable, so `discover -s tests -t .` aborts with "Start directory is not
# importable" unless tests/ carries an __init__.py, and `discover -s . -t .`
# silently runs zero tests instead. Making start and top the same directory
# needs no package marker and cannot degrade into a false green. The test module
# resolves every path from its own location, so it does not care which of the
# two directories is on sys.path.
#
# One test needs strictdoc, which only the fixture shell provides. Without it
# that test skips, and a skip inside a green run is easy to read as a pass. So
# when strictdoc is absent and the fixture shell is available, the script enters
# that shell and runs itself again there. FIXTURE_SHELL_ENTERED stops a second
# entry, so a shell that still has no strictdoc reports the skip rather than
# recursing. Nothing else changes: the same suite runs either way.
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project="$(cd -- "$here/../../../.." && pwd)"

if ! command -v strictdoc >/dev/null 2>&1 && [[ -z ${FIXTURE_SHELL_ENTERED:-} ]]; then
  if command -v devenv >/dev/null 2>&1 && [[ -f $project/devenv.nix ]]; then
    printf 'run-fixtures: strictdoc is absent; entering the fixture shell at %s\n' \
      "$project" >&2
    export FIXTURE_SHELL_ENTERED=1
    cd -- "$project"
    exec devenv shell -- "$here/run-fixtures.sh" "$@"
  fi
  printf 'run-fixtures: strictdoc is absent and no fixture shell is available, so the corpus export test will skip\n' >&2
fi

cd -- "$here"
exec python3 -m unittest discover -s tests -t tests -v "$@"
