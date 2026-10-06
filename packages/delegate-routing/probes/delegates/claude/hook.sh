#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# usage: hook.sh <logdir> <event> [response-json-file-once]
in="$(cat)"
mkdir -p "$1"
printf '%s\n' "$in" >>"$1/$2.jsonl"
if [[ $# -ge 3 && -f $3 ]]; then
  cat "$3"
  rm -f "$3"
fi
exit 0
