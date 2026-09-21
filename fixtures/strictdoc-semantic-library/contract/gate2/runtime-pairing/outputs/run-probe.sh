#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit
# Run from the supplied workspace. Optional argument reuses an existing closure.
# No argument: one build, at most 480 seconds including termination grace.
if (($# > 1)); then
  printf 'Usage: bash outputs/run-probe.sh [existing-closure-path]\n' >&2
  exit 2
fi
if (($# == 1)); then
  probe_closure=$1
else
  timeout --kill-after=5s 475s nix build --impure --file outputs/probe.nix closure --no-link --print-out-paths --max-jobs 1 --cores 2 >outputs/replay-build.out 2>outputs/replay-build.log
  probe_closure=$(cat outputs/replay-build.out)
fi
IFS= read -r probe_shebang <"$probe_closure/bin/strictdoc"
probe_interpreter=${probe_shebang#\#!}
PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$probe_closure/lib/python3.14/site-packages" timeout 30s "$probe_interpreter" -s outputs/probe.py
