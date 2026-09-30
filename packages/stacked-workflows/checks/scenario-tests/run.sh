#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
SCENARIO_ROOT="$(cd -- "$(dirname -- "$0")" && pwd)"
exec python3 "$SCENARIO_ROOT/scenarios.py" "$@"
