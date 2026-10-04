#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

read_session() (
  [[ $# -ge 1 && $# -le 2 && -d $1 && ${2:-0} =~ ^[0-9]+$ ]] || exit 2
  session_dir=$(realpath -- "$1")
  child_exit=${2:-0}
  events_file=
  shopt -s nullglob
  records=("$session_dir"/workflow/*.events.jsonl)

  failure() {
    jq -cn --arg error "$1" --arg eventsFile "$events_file" --arg sessionDir "$session_dir" \
      '{error: $error, eventsFile: (if $eventsFile == "" then null else $eventsFile end), runId: null, sessionDir: $sessionDir, status: "failed"}'
    exit 1
  }

  case ${#records[@]} in
  0)
    stderr_tail=
    if [[ -f $session_dir/stderr ]]; then stderr_tail=$(tail -c 4096 -- "$session_dir/stderr"); fi
    failure "launch/preflight failure: no workflow record; child exit=$child_exit; stderr tail: $stderr_tail"
    ;;
  1) events_file=${records[0]} ;;
  *) failure "ambiguous workflow records: ${#records[@]} files; child exit=$child_exit" ;;
  esac

  if result=$(jq -cse --arg eventsFile "$events_file" --arg sessionDir "$session_dir" \
    -f @filter@ "$events_file" 2>&1); then
    printf '%s\n' "$result"
    jq -e '.status == "completed"' <<<"$result" >/dev/null
  else
    failure "invalid workflow record: ${result: -4096}"
  fi

)

usage() {
  printf '%s\n' 'usage: kimchi-workflow-run --model ID [--input JSON|@FILE] FILE.workflow.ts' \
    '       kimchi-workflow-run --read-session DIR [CHILD_EXIT_CODE]' >&2
  exit 2
}

if [[ ${1:-} == --read-session ]]; then
  [[ $# -ge 2 && $# -le 3 ]] || usage
  read_session "$2" "${3:-0}"
  exit $?
fi

model=()
input=()
workflow=
while [[ $# -gt 0 ]]; do
  case $1 in
  --model | --input)
    [[ $# -ge 2 && -n $2 ]] || usage
    if [[ $1 == --model ]]; then model=(--model "$2"); else input=("$2"); fi
    shift 2
    ;;
  --*) usage ;;
  *)
    [[ -z $workflow ]] || usage
    workflow=$1
    shift
    ;;
  esac
done
[[ ${#model[@]} -gt 0 ]] || usage
[[ -n $workflow && -f $workflow && $workflow == *.workflow.ts ]] || usage
workflow=$(realpath -- "$workflow")
# The slash-command parser treats an isolated --input token as a delimiter.
[[ ! $workflow =~ (^|[[:space:]])--input([[:space:]]|$) ]] || usage
prompt="/workflow run $workflow"
if [[ ${#input[@]} -gt 0 ]]; then prompt+=" --input ${input[0]}"; fi

export KIMCHI_ENABLE_RESOURCES="${KIMCHI_ENABLE_RESOURCES:+${KIMCHI_ENABLE_RESOURCES},}extensions.workflows"
session_dir=$(mktemp -d "${TMPDIR:-/tmp}/kimchi-workflow.XXXXXXXX")
session_dir=$(realpath -- "$session_dir")
printf 'kimchi-workflow-run: sessionDir=%s\n' "$session_dir" >&2
child_exit=0
kimchi --mode json --session-dir "$session_dir" "${model[@]}" --thinking off -p "$prompt" \
  </dev/null >"$session_dir/stdout" 2>"$session_dir/stderr" || child_exit=$?
read_session "$session_dir" "$child_exit"
