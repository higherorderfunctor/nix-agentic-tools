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
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd -- "$here"
exec python3 -m unittest discover -s tests -t tests -v "$@"
