#!/usr/bin/env bash
#
# Self-test for the mode-F workflow definitions and for contract.jq.
#
# Seven sections, in the order a reviewer should read them:
#
#   1. the committed definitions validate as expected, including the text verdict
#   2. re-running generate.sh reproduces them (semantically, not byte-wise)
#   3. K really does live in one place — regenerate at both K boundaries and at
#      each refusal boundary, and check the derived shape follows
#   4. the negative corpus: every case is rejected FOR ITS OWN REASON
#   5. the negative corpus exercises every declared diagnostic code
#   6. the negative corpus is well-formed (sorted, unique names)
#   7. drift: the contract's constants still match the installed engine bundle
#
# WHY SECTION 4 IS SHAPED THE WAY IT IS. Mutation cases check for the expected
# diagnostic, not mere rejection. Section 1 records the base diagnostics,
# and section 4 rejects cases that expect a diagnostic already on their base.
#
# READ-ONLY with respect to Kiro state. Section 7 reads the engine bundle and
# nothing else; no section starts a session, and nothing writes under
# $HOME/.kiro. Everything else happens in a temp dir.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# source-path=SCRIPTDIR resolves the include relative to THIS script rather than
# to the caller's cwd, which is what lets `shellcheck` follow it from the repo
# root the way pre-commit invokes it. lib.sh is used for one thing only —
# kiro_resolve_bundle in section 7. Sections 1-6 deliberately touch no Kiro
# state: a validator whose whole purpose is to run BEFORE anything is seeded has
# nothing to locate.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../harness/lib.sh
. "$here/../harness/lib.sh"

validator="$here/validate-workflow.sh"
generator="$here/generate.sh"
negatives="$here/self-test-negatives.json"
contract="$here/contract.jq"

work="$(mktemp -d "${TMPDIR:-/tmp}/kiro-workflow-validate-self_test.XXXXXX")"
# shellcheck disable=SC2064  # expand $work now: it must not depend on later state
trap "rm -rf '$work'" EXIT

ok_count=0
fail_count=0
unverified_count=0

ok() {
	ok_count=$((ok_count + 1))
	printf 'ok        %s\n' "$1"
}

bad() {
	fail_count=$((fail_count + 1))
	printf 'FAIL      %s\n' "$1" >&2
}

unverified() {
	unverified_count=$((unverified_count + 1))
	printf 'UNVERIFIED %s\n' "$1" >&2
}

# Run the validator and capture both its diagnostics and its exit status without
# letting a legitimate non-zero status abort the script.
#
# Sets: rv_status, rv_json, rv_codes (newline-separated,
# deduplicated) and rv_unclassified (space-separated codes reported with no
# declared basis).
run_validator() {
	rv_status=0
	rv_json="$("$validator" --json "$@")" || rv_status=$?
	rv_codes="$(printf '%s' "$rv_json" | jq -r -s '.[].diagnostics[].code' | LC_ALL=C sort -u)"
	rv_unclassified="$(printf '%s' "$rv_json" |
		jq -r -s '[.[].diagnostics[] | select(.basis | IN("engine", "mechanical", "policy") | not) | .code] | unique | join(" ")')"
	if [ -n "$rv_unclassified" ]; then
		unclassified_seen="${unclassified_seen} ${rv_unclassified}"
	fi
}

# Accumulates any code reported with no declared basis. Section 5 turns this into
# a completeness claim: the negative corpus is proven there to exercise every
# declared code, so "nothing was ever unclassified" is the same statement as
# "every rule says whose rule it is".
unclassified_seen=""

# ---------------------------------------------------------------------------
# 1. The committed definitions validate as expected
#
# Both drains must be clean under --strict. `coverage` deliberately holds an
# `onMaxIterations: "continue"`, so it must fail --strict with just that warning.
# Section 4 checks that warnings alone do not fail plain validation and that
# `smoke` produces no diagnostics as the valid input after a missing file.
# ---------------------------------------------------------------------------

printf -- '--- 1. committed definitions ---\n'

# The same list of definitions drives the regeneration comparison in section 2.
definitions=()
declare -A base_codes=()
while IFS='|' read -r name status warning; do
	definitions+=("$name")
	file="$here/${name}.workflow.json"
	run_validator --strict "$file"
	base_codes["$name"]="$rv_codes"

	if [ "$rv_status" -eq "$status" ] && jq -es --arg file "$file" --arg warning "$warning" '
		map(.file) == [$file] and
		(.[0].diagnostics |
			if $warning == "" then . == []
			else type == "array" and map({code, severity}) == [{code: $warning, severity: "warn"}]
			end)
	' <<<"$rv_json" >/dev/null; then
		ok "${name}: strict status=${status} warnings=[${warning}]"
	else
		bad "${name}: strict expected status=${status}, no errors and warnings=[${warning}]; got status=${rv_status}"
		printf '%s\n' "$rv_json" >&2
	fi
done <<'DEFINITIONS'
coverage|1|W-ON-MAX-ITERATIONS-CONTINUE
drain|0|
drain-queue|0|
DEFINITIONS

# The human-facing verdict once said PASS even though strict mode exited 1.
# The JSON table above cannot catch that disagreement on the text path.
coverage_file="$here/coverage.workflow.json"
text_status=0
text_output="$("$validator" --strict "$coverage_file")" || text_status=$?
if [ "$text_status" -eq 1 ] &&
	[ "${text_output%%$'\n'*}" = "$coverage_file: FAIL (warnings are errors under --strict)" ]; then
	ok 'coverage: strict text verdict agrees with the warning exit status'
else
	bad "coverage: expected strict text FAIL and status 1; got status=${text_status}: ${text_output}"
fi

# ---------------------------------------------------------------------------
# 2. Regenerating reproduces the committed definitions
#
# Compared through `jq -S` (recursively key-sorted, compact) rather than by
# bytes, because treefmt's biome owns *.json formatting and would otherwise make
# every regeneration look like a change. Compare the committed copy with a
# fresh output so manual edits and stale fixtures both show up here.
# ---------------------------------------------------------------------------

printf -- '--- 2. generator reproduces the committed definitions ---\n'

regen="$work/regen"
mkdir -p "$regen"
cp "$generator" "$regen/generate.sh"
env -u DRAIN_BRANCHES bash "$regen/generate.sh" >/dev/null

canonical() { jq -S -c . "$1"; }

# Smoke is validated in section 4 but is still a generated definition.
for name in "${definitions[@]}" smoke; do
	if [ "$(canonical "$here/${name}.workflow.json")" = "$(canonical "$regen/${name}.workflow.json")" ]; then
		ok "${name}.workflow.json matches a fresh generator run"
	else
		bad "${name}.workflow.json differs from a fresh generator run — re-run generate.sh"
	fi
done

# ---------------------------------------------------------------------------
# 3. K lives in exactly one place
#
# Regenerate at both accepted boundaries and check that every K-derived quantity
# followed: structural step-node count and one exact stop path per branch.
# Two branches sharing a shard file is not a validation error (ids still differ,
# paths are still legal), but at runtime one shard is processed twice and
# another is never touched. Pin the shard files by name: even disjoint paths
# could point to the wrong shards. The queue drain instead needs every claimant
# to wait on the SAME published flag; a sharded stop path would strand workers.
# ---------------------------------------------------------------------------

printf -- '--- 3. the K knob ---\n'

k_dir="$work/branches"
mkdir -p "$k_dir"
cp "$generator" "$k_dir/generate.sh"
expected_shards=(.kiro-harness/drain/shard-{01..20}.json)
# Empty catches accidental defaulting; -1 catches acceptance of signed input
# before the minimum check, while abc catches a missing decimal gate altogether.
while IFS='|' read -r k refusal; do
	label="K=${k:-<empty>}"
	gen_status=0
	gen_output="$(DRAIN_BRANCHES="$k" bash "$k_dir/generate.sh" 2>&1)" || gen_status=$?
	if [ -n "$refusal" ]; then
		if [ "$gen_status" -eq 1 ] && [[ $gen_output == "refusing: "*"$refusal"* ]]; then
			ok "${label}: refused (${refusal})"
		else
			bad "${label}: expected status 1 with '${refusal}'; got status=${gen_status}: ${gen_output}"
		fi
		continue
	elif [ "$gen_status" -ne 0 ]; then
		bad "${label}: expected successful generation; got status=${gen_status}: ${gen_output}"
		continue
	fi

	for name in drain drain-queue; do
		file="$k_dir/${name}.workflow.json"
		case "$name" in
		drain) paths="$(printf '%s\n' "${expected_shards[@]:0:k}")" ;;
		drain-queue) paths=".kiro-harness/queue/status.json" ;;
		*)
			bad "${name} ${label}: no expected stop path is declared for this definition"
			continue
			;;
		esac

		# Keep the comparison independent of the generator's path formatter.
		# Each false key names which observable invariant broke.
		shape_failed="$(jq -r --argjson k "$k" --arg name "$name" --arg paths "$paths" '
			{
				drained_flag: all(.steps[0].branches[].stopCondition.fileCheck;
					.jsonPath == "drained" and .value == true),
				paths: ([.steps[0].branches[].stopCondition.fileCheck.path] | sort) ==
					(if $name == "drain" then ($paths | split("\n")) else [range($k) | $paths] end),
				steps: ([.. | objects | select(.type == "step")] | length) == $k
			}
			| to_entries | map(select(.value != true) | .key) | join(", ")
		' "$file")"
		if [ -z "$shape_failed" ]; then
			ok "${name} ${label}: step count and exact stop flags and paths"
		else
			bad "${name} ${label}: wrong shape: ${shape_failed}"
		fi

		# Strict validation requires allSettled joins and abort on exhaustion.
		# At 20 it also ties the generator's accepted boundary to the contract's.
		run_validator --strict "$file"
		if [ "$rv_status" -eq 0 ] && [ -z "$rv_codes" ]; then
			ok "${name} ${label}: generated definition passes --strict with no diagnostics"
		else
			bad "${name} ${label}: generated definition does not pass --strict cleanly"
			printf '%s\n' "$rv_json" >&2
		fi
	done
done <<'BRANCH_COUNTS'
|DRAIN_BRANCHES must be a decimal integer
-1|DRAIN_BRANCHES must be a decimal integer
0|a drain needs at least one branch
1|
20|
21|exceeds maxStepNodes=20
abc|DRAIN_BRANCHES must be a decimal integer
BRANCH_COUNTS

# ---------------------------------------------------------------------------
# 4. The negative corpus
# ---------------------------------------------------------------------------

printf -- '--- 4. negative corpus ---\n'

case_total="$(jq '.cases | length' "$negatives")"

neg_dir="$work/negatives"
mkdir -p "$neg_dir"

while IFS= read -r rec; do
	case_name="$(printf '%s' "$rec" | jq -r '.name')"
	case_code="$(printf '%s' "$rec" | jq -r '.code')"
	case_severity="$(printf '%s' "$rec" | jq -r '.severity // "error"')"
	case_base="$(printf '%s' "$rec" | jq -r '.base // ""')"
	# Distinguish local policy from engine containment and driver failures.
	case_basis="$(printf '%s' "$rec" | jq -r '.basis // ""')"
	target="$neg_dir/${case_name}.workflow.json"
	files=("$target")

	# A third case kind, for the one diagnostic whose subject is the ABSENCE of a
	# file. It cannot be expressed as `raw` (there is no content to write) or as
	# `base`+`mutate` (there is nothing to mutate), so the case asserts the target
	# is never created. `rm -f` rather than merely skipping the write, because a
	# target name is derived from the case name and must not survive a re-run.
	if [ "$(printf '%s' "$rec" | jq -r 'has("absent")')" = "true" ]; then
		rm -f "$target"
		# A missing file must not shift the output record for a following input.
		files+=("$here/smoke.workflow.json")
	elif [ "$(printf '%s' "$rec" | jq -r 'has("raw")')" = "true" ]; then
		printf '%s' "$rec" | jq -j -r '.raw' >"$target"
	else
		if [ -z "$case_base" ]; then
			bad "${case_name}: neither 'base'+'mutate' nor 'raw' nor 'absent' is set"
			continue
		fi
		if [ -z "${base_codes[$case_base]+present}" ]; then
			bad "${case_name}: no baseline diagnostics recorded for ${case_base}"
			continue
		fi
		if grep -Fx -- "$case_code" <<<"${base_codes[$case_base]}" >/dev/null; then
			bad "${case_name}: ${case_code} is already reported on the clean ${case_base} base — the case is not attributable"
			continue
		fi
		mutate="$(printf '%s' "$rec" | jq -r '.mutate')"
		if ! jq "$mutate" "$here/${case_base}.workflow.json" >"$target" 2>"$work/jq_error"; then
			bad "${case_name}: the mutation is not a valid jq expression: $(cat "$work/jq_error")"
			continue
		fi
	fi

	run_validator "${files[@]}"
	if [ "${#files[@]}" -gt 1 ] && ! jq -es '
		map(.file) == $ARGS.positional and .[1].diagnostics == []
	' --args "${files[@]}" <<<"$rv_json" >/dev/null; then
		bad "${case_name}: expected one record per input in order and no smoke diagnostics; got ${rv_json}"
		continue
	fi

	if ! jq -es --arg code "$case_code" --arg severity "$case_severity" --arg basis "$case_basis" '
		any(.[0].diagnostics[];
			.code == $code and .severity == $severity and ($basis == "" or .basis == $basis))
	' <<<"$rv_json" >/dev/null; then
		bad "${case_name}: expected ${case_severity} ${case_code}${case_basis:+ with basis ${case_basis}}; got ${rv_json}"
		continue
	fi

	if [ "$case_severity" = "warn" ]; then
		if [ "$rv_status" -ne 0 ]; then
			bad "${case_name}: a warning must not fail plain validation"
			continue
		fi
		ok "${case_name}: warns ${case_code} and passes plain validation"
	else
		if [ "$rv_status" -ne 1 ]; then
			bad "${case_name}: expected status 1 for ${case_code}; got ${rv_status}"
			continue
		fi
		ok "${case_name}: rejected with ${case_code}"
	fi
done < <(jq -c '.cases[]' "$negatives")

# ---------------------------------------------------------------------------
# 5. The negative corpus is complete
#
# Every declared diagnostic must have a case: a new code can otherwise ship
# without evidence that its rule fires. Section 4 already proves the reverse by
# requiring every case's code to appear in a real validator run.
#
# The codes are read out of the two files that emit them by matching a QUOTED
# code literal, so a code merely mentioned inside a prose message (several are,
# by cross-reference) is not miscounted as a declaration.
# ---------------------------------------------------------------------------

printf -- '--- 5. corpus completeness ---\n'

declared="$work/declared-codes"
tested="$work/tested-codes"

{ grep -ohE '"(E|W)-[A-Z0-9-]+"' "$contract" "$validator" || true; } |
	tr -d '"' | LC_ALL=C sort -u >"$declared"
jq -r '.cases[].code' "$negatives" | LC_ALL=C sort -u >"$tested"

declared_n="$(wc -l <"$declared")"
tested_n="$(wc -l <"$tested")"

if [ "$declared_n" -eq 0 ]; then
	bad "no diagnostic codes were extracted from the validator — the extraction is broken, not the corpus"
else
	# LC_ALL=C on `comm` as well as on the sorts, and the status captured rather
	# than left to `set -e`. Both halves were found by mutation-testing this file:
	# the inputs are C-sorted, but `comm` under en_US.UTF-8 ignores punctuation at
	# the primary collation level, so it ranks E-STEP-NODES-MAX before
	# E-STEP-NO-PROMPT-OR-INPUT and declares C-sorted input unsorted. GNU comm only
	# notices when the files actually diverge, so this was invisible while the
	# corpus was complete and broke exactly when a code went untested — the one run
	# that had to work. It then exited 1, which `set -e` turned into a silent abort
	# partway through section 5: no FAIL line, no summary, just a non-zero status.
	comm_status=0
	untested="$(LC_ALL=C comm -23 "$declared" "$tested")" || comm_status=$?
	if [ "$comm_status" -ne 0 ]; then
		bad "the code-set comparison failed (comm exited ${comm_status}) — completeness is unproven"
	elif [ -z "$untested" ]; then
		ok "all ${declared_n} declared diagnostic codes are exercised (${tested_n} tested)"
	else
		bad "declared but never exercised: $(printf '%s' "$untested" | tr '\n' ' ')"
	fi
fi

# Because the corpus above is proven to exercise every declared code, a run in
# which nothing was ever reported as "unclassified" proves every rule declares
# whose rule it is — engine, policy, or mechanical. That matters more than
# bookkeeping: `policy` means the engine ACCEPTS the thing being rejected, and an
# author who cannot tell the two apart cannot judge a rejection.
if [ -z "${unclassified_seen// /}" ]; then
	ok "every diagnostic reported in this run carries a declared basis"
else
	bad "codes reported with no declared basis:${unclassified_seen}"
fi

# ---------------------------------------------------------------------------
# 6. The negative corpus is well-formed
# ---------------------------------------------------------------------------

printf -- '--- 6. corpus hygiene ---\n'

corpus_order="$(jq -r '.cases[] | .code + " " + .name' "$negatives")"
if [ "$corpus_order" = "$(printf '%s\n' "$corpus_order" | LC_ALL=C sort)" ]; then
	ok "the corpus is sorted by (code, name)"
else
	bad "the corpus is not sorted by (code, name)"
fi

dupe_names="$(jq -r '.cases[].name' "$negatives" | LC_ALL=C sort | uniq -d)"
if [ -z "$dupe_names" ]; then
	ok "case names are unique"
else
	bad "duplicate case names: $(printf '%s' "$dupe_names" | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# 7. Drift: the contract's constants still match the installed engine
#
# contract.jq is a TRANSCRIPTION of a bundle read. Section 1-6 prove it is
# self-consistent; only this section can tell you it still describes the engine
# on this machine. Both sides are extracted, so no expected value is written
# down here a third time.
#
# Three outcomes, kept distinct on purpose:
#   ok          both sides found and equal
#   FAIL        both sides found and DIFFERENT — real drift, stop and fix
#   UNVERIFIED  a pattern could not be located, so the comparison did not happen
#
# An UNVERIFIED is not a pass. It usually means a CLI upgrade moved the bundle's
# shape, which the corpus README calls a question rather than a failure — but a
# contract that cannot be confirmed against the installed engine must not read as
# green, so it is printed loudly and counted separately. All seven unverified is
# treated as a hard failure: that is an extraction that has lost its grip, and it
# is indistinguishable from a clean run if left uncounted.
# ---------------------------------------------------------------------------

printf -- '--- 7. drift against the installed engine ---\n'

drift_ran=0

# Compare two extracted values, refusing on either side being empty.
compare_drift() {
	local label="$1" from_bundle="$2" from_contract="$3"
	if [ -z "$from_bundle" ] || [ -z "$from_contract" ]; then
		unverified "${label}: bundle=[${from_bundle}] contract=[${from_contract}] — a side could not be located"
		return 0
	fi
	drift_ran=$((drift_ran + 1))
	if [ "$from_bundle" = "$from_contract" ]; then
		ok "${label}: bundle and contract.jq agree (${from_bundle})"
	else
		bad "${label}: DRIFT — bundle=[${from_bundle}] contract.jq=[${from_contract}]"
	fi
}

# Quoted string literals inside the first match of a pattern, sorted, so the
# comparison is set-wise and independent of declaration order.
literal_set() {
	local pattern="$1" file="$2"
	{ grep -m1 -oE "$pattern" "$file" || true; } |
		{ grep -oE '"[a-zA-Z_]+"' || true; } |
		tr -d '"' | LC_ALL=C sort | tr '\n' ',' | sed 's/,$//'
}

# The one integer inside the first match of a pattern.
literal_int() {
	local pattern="$1" file="$2"
	{ grep -m1 -oE "$pattern" "$file" || true; } |
		{ grep -oE '[0-9]+(e[0-9]+)?$' || true; } |
		{
			read -r raw || raw=""
			[ -z "$raw" ] && return 0
			awk -v v="$raw" 'BEGIN { printf "%d", v + 0 }'
		}
}

bundle=""
if bundle_row="$(kiro_resolve_bundle 2>/dev/null)"; then
	bundle="$(printf '%s' "$bundle_row" | cut -f2)"
fi

if [ -z "$bundle" ]; then
	unverified "the engine bundle could not be resolved — no drift check ran"
else
	printf 'bundle:   %s\n' "$bundle"

	# Enum members. `[A-Za-z_0-9$]+\.` rather than a literal `external_exports2.`
	# because the collision suffixes the bundler appends churn between releases and are
	# explicitly untrustworthy as anchors.
	compare_drift "enum completionSignal" \
		"$(literal_set 'completionSignal: [A-Za-z_0-9$]+\.enum\(\[[^]]*\]\)' "$bundle")" \
		"$(literal_set 'def enum_completion_signal: \[[^]]*\]' "$contract")"
	compare_drift "enum joinPolicy" \
		"$(literal_set 'JoinPolicySchema = [A-Za-z_0-9$]+\.enum\(\[[^]]*\]\)' "$bundle")" \
		"$(literal_set 'def enum_join_policy: \[[^]]*\]' "$contract")"
	compare_drift "enum nodeType" \
		"$(literal_set 'NodeTypeSchema = [A-Za-z_0-9$]+\.enum\(\[[^]]*\]\)' "$bundle")" \
		"$(literal_set 'def enum_node_type: \[[^]]*\]' "$contract")"
	compare_drift "enum onMaxIterations" \
		"$(literal_set 'OnMaxIterationsSchema = [A-Za-z_0-9$]+\.enum\(\[[^]]*\]\)' "$bundle")" \
		"$(literal_set 'def enum_on_max_iterations: \[[^]]*\]' "$contract")"

	# Numeric ceilings. The bundle writes the iteration ceiling as `1e3`, which is
	# why literal_int normalizes through awk rather than comparing strings.
	compare_drift "limit maxNestingDepth" \
		"$(literal_int 'DEFAULT_MAX_NESTING_DEPTH = [0-9]+' "$bundle")" \
		"$(literal_int 'def limit_max_nesting_depth: [0-9]+' "$contract")"
	compare_drift "limit maxRepeatIterations" \
		"$(literal_int 'MAX_REPEAT_ITERATIONS = [0-9]+e?[0-9]*' "$bundle")" \
		"$(literal_int 'def limit_max_repeat_iterations: [0-9]+' "$contract")"
	compare_drift "limit maxStepNodes" \
		"$(literal_int 'DEFAULT_MAX_STEP_NODES = [0-9]+' "$bundle")" \
		"$(literal_int 'def limit_max_step_nodes: [0-9]+' "$contract")"

	if [ "$drift_ran" -eq 0 ]; then
		bad "every drift comparison was unverified — the extraction has lost its grip on the bundle"
	fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf -- '--- summary ---\n'
printf 'checks passed:      %d\n' "$ok_count"
printf 'checks failed:      %d\n' "$fail_count"
printf 'unverified:         %d\n' "$unverified_count"
printf 'negative cases:     %d\n' "$case_total"
printf 'diagnostic codes:   %d declared / %d exercised\n' "${declared_n:-0}" "${tested_n:-0}"

# A denominator of zero is not a pass. "Nothing failed" is vacuous if nothing
# ran, and that is exactly how a broken enumeration presents.
if [ "$ok_count" -eq 0 ]; then
	echo 'FAIL: no check actually ran' >&2
	exit 1
fi
if [ "$fail_count" -ne 0 ]; then
	printf 'FAIL: %d check(s) did not pass\n' "$fail_count" >&2
	exit 1
fi
if [ "$unverified_count" -ne 0 ]; then
	printf 'PASS with %d unverified check(s) — read the UNVERIFIED lines above\n' "$unverified_count"
	exit 0
fi
echo 'PASS'
