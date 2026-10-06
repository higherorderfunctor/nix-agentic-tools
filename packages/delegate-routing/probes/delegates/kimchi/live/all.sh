#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# usage: all.sh [<scenario-name>...]   — re-runs the offline Kimchi delegate scenarios (default: every sc/*.json)
# against the scripted fake provider. No account, no network beyond 127.0.0.1, except that
# `/workflow run` scenarios (w*) let kimchi-workflows provision with pnpm, which may reach the npm registry.
# Each run: <work>/<name>/{provider.jsonl,stdout,stderr,meta.json,summary.txt}; work = $PROBE_OUT/kimchi or a temp dir.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../common/pin.sh
source "$here/../../common/pin.sh"
work="$(probe_workdir kimchi)"
if [[ $# -eq 0 ]]; then
  for f in "$here"/sc/*.json; do set -- "$@" "$(basename "$f" .json)"; done
fi
for n in "$@"; do
  python3 "$here/drive.py" "$here/sc/$n.json" "$work/$n"
  python3 "$here/summ.py" "$work/$n" >"$work/$n/summary.txt" || :
done
printf 'work: %s\n' "$work"
