#!/usr/bin/env bash
# This file is sourced into the deliberately non-errexit agent shell.
# Setting strict mode here would change the behavior under test.
git() {
  local trace_rc=0 trace_out trace_err trace_command trace_kind trace_mutator=0 trace_selection
  trace_out="$(mktemp "$TMPDIR/query-output.XXXXXX")"
  trace_err="$(mktemp "$TMPDIR/query-error.XXXXXX")"
  trace_command="$*"
  trace_kind="${1:-}"
  case "$trace_kind" in
  absorb | add | amend | checkout | commit | hide | move | rebase | reset | restack | restore | revise | submit)
    trace_mutator=1
    ;;
  branch)
    if [ "${2:-}" != --show-current ]; then trace_mutator=1; fi
    ;;
  test)
    if [ "${2:-}" = fix ]; then trace_mutator=1; fi
    ;;
  *) ;;
  esac
  if [ "$trace_mutator" = 1 ]; then
    if [ "$SCENARIO_SELECTION" = 1 ] && [ -n "${SELECTED:-${STACK:-}}" ]; then
      trace_selection="${SELECTED:-$STACK}"
      command git query -r "$trace_selection" >"$trace_out" 2>"$trace_err" || trace_rc=$?
      if [ "$trace_rc" -ne 0 ]; then
        printf '%s\tquery-error\t%s\tpre-mutation selection: %s\n' "$SCENARIO_STEP" "$trace_rc" "$trace_selection" >>"$SCENARIO_TRACE"
      elif [ ! -s "$trace_out" ]; then
        printf '%s\tempty-selection\t0\tpre-mutation selection: %s\n' "$SCENARIO_STEP" "$trace_selection" >>"$SCENARIO_TRACE"
      fi
      trace_rc=0
    fi
    printf '%s\tmutator\t0\t%s\n' "$SCENARIO_STEP" "$trace_command" >>"$SCENARIO_TRACE"
  fi
  command git "$@" >"$trace_out" 2>"$trace_err" || trace_rc=$?
  if [ "$trace_kind" = query ]; then
    if [ "$trace_rc" -ne 0 ]; then
      printf '%s\tquery-error\t%s\t%s\n' "$SCENARIO_STEP" "$trace_rc" "$trace_command" >>"$SCENARIO_TRACE"
    elif [ ! -s "$trace_out" ] && [ "$SCENARIO_SELECTION" = 1 ]; then
      case "$trace_command" in
      "query ${SELECTED:-__unset__}" | "query -r ${SELECTED:-__unset__}")
        printf '%s\tempty-selection\t0\t%s\n' "$SCENARIO_STEP" "$trace_command" >>"$SCENARIO_TRACE"
        ;;
      *) ;;
      esac
    fi
  fi
  cat "$trace_out"
  cat "$trace_err" >&2
  return "$trace_rc"
}
