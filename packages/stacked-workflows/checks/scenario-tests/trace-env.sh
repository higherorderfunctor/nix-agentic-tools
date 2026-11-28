#!/usr/bin/env bash
# This file is sourced into the deliberately non-errexit agent shell.
# Setting strict mode here would change the behavior under test.
scenario_trace_query() {
	local status="$1" output="$2" check_empty="$3" label="$4"
	if [ "$status" -ne 0 ]; then
		printf '%s\tquery-error\t%s\t%s\n' "$SCENARIO_STEP" "$status" "$label" >>"$SCENARIO_TRACE"
	elif [ "$check_empty" = 1 ] && [ ! -s "$output" ]; then
		printf '%s\tempty-selection\t0\t%s\n' "$SCENARIO_STEP" "$label" >>"$SCENARIO_TRACE"
	fi
}

git() {
	local trace_rc=0 trace_out trace_err trace_command trace_kind trace_mutator=0
	local trace_selection trace_selection_rc=0 trace_check_empty=0
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
		# A block can skip its query or change the selection before writing.
		# Observe the selection at the write, even if the write itself fails.
		if [ "$SCENARIO_SELECTION" = 1 ] && [ -n "${SELECTED:-${STACK:-}}" ]; then
			trace_selection="${SELECTED:-$STACK}"
			command git query -r "$trace_selection" >"$trace_out" 2>"$trace_err" || trace_selection_rc=$?
			scenario_trace_query "$trace_selection_rc" "$trace_out" 1 "pre-mutation selection: $trace_selection"
		fi
		printf '%s\tmutator\t0\t%s\n' "$SCENARIO_STEP" "$trace_command" >>"$SCENARIO_TRACE"
	fi
	command git "$@" >"$trace_out" 2>"$trace_err" || trace_rc=$?
	# Catch ignored query errors even if a later query succeeds. Only a
	# selection itself must be nonempty; a query for exclusions may be empty.
	if [ "$trace_kind" = query ]; then
		if [ "$SCENARIO_SELECTION" = 1 ]; then
			case "$trace_command" in
			"query -r ${SELECTED:-__unset__}")
				trace_check_empty=1
				;;
			*) ;;
			esac
		fi
		scenario_trace_query "$trace_rc" "$trace_out" "$trace_check_empty" "$trace_command"
	fi
	cat "$trace_out"
	cat "$trace_err" >&2
	return "$trace_rc"
}
