#!/usr/bin/env bash
#
# Self-test for the mode-F workflow definitions and for contract.jq.
#
# Seven sections, in the order a reviewer should read them:
#
#   1. the committed definitions validate as expected
#   2. re-running generate.sh reproduces them (semantically, not byte-wise)
#   3. K really does live in one place — regenerate at both K boundaries and at
#      each refusal boundary, and check the derived shape follows
#   4. the negative corpus: every case is rejected FOR ITS OWN REASON
#   5. the negative corpus is complete — every code the validator can emit is
#      exercised, and all four documented authoring traps are represented
#   6. the negative corpus is well-formed (sorted, unique names)
#   7. drift: the contract's constants still match the installed engine bundle
#
# WHY SECTION 4 IS SHAPED THE WAY IT IS. Each negative is a single mutation of a
# definition that section 1 has already proven clean, and the assertion is not
# merely "the mutant was rejected" but "the mutant reported the expected code AND
# the clean base did not". Without that second half a mutation that broke the
# file in some unrelated way would score as a pass for the rule it was supposed
# to test. Section 4 also runs a NO-OP mutation as a control: `jq .` round-trips
# the drain and it must still pass, which is what rules out the mutation pipeline
# itself manufacturing the failures.
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

for required in "$contract" "$generator" "$negatives" "$validator"; do
  if [ ! -f "$required" ]; then
    echo "missing required file: ${required}" >&2
    exit 1
  fi
done

work="$(mktemp -d "${TMPDIR:-/tmp}/kiro-workflow-validate-self_test.XXXXXX")"
# shellcheck disable=SC2064  # expand $work now: it must not depend on later state
trap "rm -rf '$work'" EXIT

# The three definitions generate.sh emits, in the order it emits them.
readonly DEFINITIONS=(coverage drain smoke)

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
# Sets: rv_status, rv_json, rv_errors, rv_warnings, rv_codes (newline-separated,
# deduplicated) and rv_unclassified (space-separated codes reported with no
# declared basis).
run_validator() {
  rv_status=0
  rv_json="$("$validator" --json "$@")" || rv_status=$?
  rv_errors="$(printf '%s' "$rv_json" | jq -s '[.[].diagnostics[] | select(.severity == "error")] | length')"
  rv_warnings="$(printf '%s' "$rv_json" | jq -s '[.[].diagnostics[] | select(.severity == "warn")] | length')"
  rv_codes="$(printf '%s' "$rv_json" | jq -r -s '.[].diagnostics[].code' | LC_ALL=C sort -u)"
  rv_unclassified="$(printf '%s' "$rv_json" |
    jq -r -s '[.[].diagnostics[] | select(.basis == "unclassified") | .code] | unique | join(" ")')"
  if [ -n "$rv_unclassified" ]; then
    unclassified_seen="${unclassified_seen} ${rv_unclassified}"
  fi
}

# Accumulates any code reported with no declared basis. Section 5 turns this into
# a completeness claim: the negative corpus is proven there to exercise every
# declared code, so "nothing was ever unclassified" is the same statement as
# "every rule says whose rule it is".
unclassified_seen=""

# Is $2 one of the newline-separated codes in $1?
has_code() {
  printf '%s\n' "$1" | grep -qxF "$2"
}

# ---------------------------------------------------------------------------
# 1. The committed definitions validate as expected
#
# `drain` and `smoke` are meant to be run unattended, so they must be clean
# under --strict. `coverage` is a validator fixture that deliberately holds an
# `onMaxIterations: "continue"`, so it must pass PLAIN validation and FAIL
# --strict — which is what proves the warning channel is wired to the exit code
# rather than being decorative.
# ---------------------------------------------------------------------------

printf -- '--- 1. committed definitions ---\n'

for name in drain smoke; do
  file="$here/${name}.workflow.json"
  run_validator --strict "$file"
  if [ "$rv_status" -eq 0 ] && [ "$rv_errors" -eq 0 ] && [ "$rv_warnings" -eq 0 ]; then
    ok "${name}.workflow.json passes --strict with no diagnostics"
  else
    bad "${name}.workflow.json: status=${rv_status} errors=${rv_errors} warnings=${rv_warnings}"
    printf '%s\n' "$rv_json" >&2
  fi
done

run_validator "$here/coverage.workflow.json"
if [ "$rv_status" -eq 0 ] && [ "$rv_errors" -eq 0 ] && [ "$rv_warnings" -ge 1 ]; then
  ok "coverage.workflow.json passes plain validation with ${rv_warnings} warning(s)"
else
  bad "coverage.workflow.json: expected 0 errors and >=1 warning, got errors=${rv_errors} warnings=${rv_warnings}"
fi

run_validator --strict "$here/coverage.workflow.json"
if [ "$rv_status" -ne 0 ]; then
  ok "coverage.workflow.json FAILS --strict (warnings reach the exit code)"
else
  bad "coverage.workflow.json passed --strict despite warnings — --strict is not wired up"
fi

# Record each definition's own diagnostic codes. Section 4 uses these to prove a
# mutant's code came from the mutation and not from the base.
declare -A base_codes=()
for name in "${DEFINITIONS[@]}"; do
  run_validator "$here/${name}.workflow.json"
  base_codes["$name"]="$rv_codes"
done

# ---------------------------------------------------------------------------
# 2. Regenerating reproduces the committed definitions
#
# Compared through `jq -S` (recursively key-sorted, compact) rather than by
# bytes, because treefmt's biome owns *.json formatting and would otherwise make
# every regeneration look like a change. The tamper control below is what stops
# this from being a comparison that cannot fail.
# ---------------------------------------------------------------------------

printf -- '--- 2. generator reproduces the committed definitions ---\n'

regen="$work/regen"
mkdir -p "$regen"
cp "$generator" "$regen/generate.sh"
bash "$regen/generate.sh" >/dev/null

canonical() { jq -S -c . "$1"; }

for name in "${DEFINITIONS[@]}"; do
  if [ "$(canonical "$here/${name}.workflow.json")" = "$(canonical "$regen/${name}.workflow.json")" ]; then
    ok "${name}.workflow.json matches a fresh generator run"
  else
    bad "${name}.workflow.json differs from a fresh generator run — re-run generate.sh"
  fi
done

jq '.name = "tampered"' "$regen/drain.workflow.json" >"$work/tampered.json"
if [ "$(canonical "$here/drain.workflow.json")" != "$(canonical "$work/tampered.json")" ]; then
  ok "control: the canonical comparison detects a one-field tamper"
else
  bad "control: the canonical comparison did NOT detect a tamper — it cannot fail"
fi

# ---------------------------------------------------------------------------
# 3. K lives in exactly one place
#
# Regenerate at both accepted boundaries and check that every K-derived quantity
# followed: branch count, structural step-node count, and the number of DISTINCT
# shard state paths. That last one is the check that matters — two branches
# sharing a shard file is not a validation error (ids still differ, paths are
# still legal), so a K hardcoded in the path template would pass every other
# assertion here and present at run time as one shard processed twice and
# another never touched.
# ---------------------------------------------------------------------------

printf -- '--- 3. the K knob ---\n'

for k in 1 20; do
  k_dir="$work/k${k}"
  mkdir -p "$k_dir"
  cp "$generator" "$k_dir/generate.sh"
  DRAIN_BRANCHES="$k" bash "$k_dir/generate.sh" >/dev/null

  shape="$(jq -c --argjson k "$k" '{
    branches: (.steps[0].branches | length) == $k,
    steps: ([.. | objects | select(.type == "step")] | length) == $k,
    distinct_shards: ([.steps[0].branches[].stopCondition.fileCheck.path] | unique | length) == $k,
    join: .steps[0].joinPolicy == "allSettled",
    on_max: ([.steps[0].branches[].onMaxIterations] | unique) == ["abort"]
  }' "$k_dir/drain.workflow.json")"

  # Name the failing sub-checks rather than diffing against a literal expected
  # JSON string. The literal form was here first and was wrong within one rename:
  # a key renamed inside the jq program above left the expectation stale, so the
  # comparison failed for a reason that had nothing to do with K. Deriving the
  # verdict from the values cannot go stale that way, and it reports WHICH
  # invariant broke instead of dumping both objects at the reader.
  shape_failed="$(printf '%s' "$shape" | jq -r 'to_entries | map(select(.value != true) | .key) | join(", ")')"
  if [ -z "$shape_failed" ]; then
    ok "K=${k}: branch count, step-node count and distinct shard paths all follow K"
  else
    bad "K=${k}: these invariants do not follow K: ${shape_failed}"
  fi

  run_validator --strict "$k_dir/drain.workflow.json"
  if [ "$rv_status" -eq 0 ]; then
    ok "K=${k}: the generated drain passes --strict"
  else
    bad "K=${k}: the generated drain does not pass --strict"
    printf '%s\n' "$rv_json" >&2
  fi
done

for k in 0 21 -1 abc ''; do
  k_dir="$work/k_refusal"
  rm -rf "$k_dir"
  mkdir -p "$k_dir"
  cp "$generator" "$k_dir/generate.sh"
  gen_status=0
  DRAIN_BRANCHES="$k" bash "$k_dir/generate.sh" >/dev/null 2>&1 || gen_status=$?
  if [ "$gen_status" -ne 0 ]; then
    ok "K=${k:-<empty>}: the generator refuses"
  else
    bad "K=${k:-<empty>}: the generator accepted an out-of-range branch count"
  fi
done

# ---------------------------------------------------------------------------
# 4. The negative corpus
# ---------------------------------------------------------------------------

printf -- '--- 4. negative corpus ---\n'

case_total="$(jq '.cases | length' "$negatives")"
if [ "$case_total" -eq 0 ]; then
  bad "the negative corpus is empty — a validator that has rejected nothing is not evidence"
fi

# Control: the mutation pipeline is a jq round-trip plus a validator call, and
# neither may introduce a diagnostic on its own.
jq '.' "$here/drain.workflow.json" >"$work/noop.workflow.json"
run_validator --strict "$work/noop.workflow.json"
if [ "$rv_status" -eq 0 ] && [ "$rv_errors" -eq 0 ]; then
  ok "control: a no-op jq mutation of the drain still passes --strict"
else
  bad "control: a no-op jq mutation FAILED — the pipeline itself manufactures diagnostics"
fi

neg_dir="$work/negatives"
mkdir -p "$neg_dir"

while IFS= read -r rec; do
  case_name="$(printf '%s' "$rec" | jq -r '.name')"
  case_code="$(printf '%s' "$rec" | jq -r '.code')"
  case_severity="$(printf '%s' "$rec" | jq -r '.severity // "error"')"
  case_base="$(printf '%s' "$rec" | jq -r '.base // ""')"
  target="$neg_dir/${case_name}.workflow.json"

  # A third case kind, for the one diagnostic whose subject is the ABSENCE of a
  # file. It cannot be expressed as `raw` (there is no content to write) or as
  # `base`+`mutate` (there is nothing to mutate), so the case asserts the target
  # is never created. `rm -f` rather than merely skipping the write, because a
  # target name is derived from the case name and must not survive a re-run.
  if [ "$(printf '%s' "$rec" | jq -r 'has("absent")')" = "true" ]; then
    rm -f "$target"
  elif [ "$(printf '%s' "$rec" | jq -r 'has("raw")')" = "true" ]; then
    printf '%s' "$rec" | jq -j -r '.raw' >"$target"
  else
    if [ -z "$case_base" ]; then
      bad "${case_name}: neither 'base'+'mutate' nor 'raw' nor 'absent' is set"
      continue
    fi
    mutate="$(printf '%s' "$rec" | jq -r '.mutate')"
    if ! jq "$mutate" "$here/${case_base}.workflow.json" >"$target" 2>"$work/jq_error"; then
      bad "${case_name}: the mutation is not a valid jq expression: $(cat "$work/jq_error")"
      continue
    fi
  fi

  run_validator "$target"

  # Attribution: the code must NOT already be present on the clean base, or the
  # case proves nothing about its own mutation.
  if [ -n "$case_base" ] && has_code "${base_codes[$case_base]}" "$case_code"; then
    bad "${case_name}: ${case_code} is already reported on the clean ${case_base} base — the case is not attributable"
    continue
  fi

  if ! has_code "$rv_codes" "$case_code"; then
    bad "${case_name}: expected ${case_code}, got [$(printf '%s' "$rv_codes" | tr '\n' ' ')]"
    continue
  fi

  if [ "$case_severity" = "warn" ]; then
    if [ "$rv_errors" -ne 0 ]; then
      bad "${case_name}: expected a warning but got ${rv_errors} error(s)"
      continue
    fi
    if [ "$rv_status" -ne 0 ]; then
      bad "${case_name}: a warning must not fail plain validation"
      continue
    fi
    strict_status=0
    "$validator" --strict "$target" >/dev/null 2>&1 || strict_status=$?
    if [ "$strict_status" -eq 0 ]; then
      bad "${case_name}: the warning did not fail --strict"
      continue
    fi
    ok "${case_name}: warns ${case_code}, passes plain, fails --strict"
  else
    if [ "$rv_status" -eq 0 ]; then
      bad "${case_name}: expected a non-zero exit for ${case_code}"
      continue
    fi
    if [ "$rv_errors" -lt 1 ]; then
      bad "${case_name}: ${case_code} was reported but the error count is ${rv_errors}"
      continue
    fi
    ok "${case_name}: rejected with ${case_code}"
  fi
done < <(jq -c '.cases[]' "$negatives")

# ---------------------------------------------------------------------------
# 5. The negative corpus is complete
#
# Every diagnostic code the validator can emit must be exercised by at least one
# case, in both directions: an untested code is a rule nobody has ever seen fire,
# and a tested code that the validator cannot emit is a typo in the corpus.
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
  unknown="$(LC_ALL=C comm -13 "$declared" "$tested")" || comm_status=$?
  if [ "$comm_status" -ne 0 ]; then
    bad "the code-set comparison failed (comm exited ${comm_status}) — completeness is unproven"
  elif [ -z "$untested" ]; then
    ok "all ${declared_n} declared diagnostic codes are exercised (${tested_n} tested)"
  else
    bad "declared but never exercised: $(printf '%s' "$untested" | tr '\n' ' ')"
  fi
  if [ -z "$unknown" ]; then
    ok "every tested code is one the validator can actually emit"
  else
    bad "tested but not emitted by the validator: $(printf '%s' "$unknown" | tr '\n' ' ')"
  fi
fi

for trap_id in 1 2 3 4; do
  trap_n="$(jq --argjson t "$trap_id" '[.cases[] | select(.trap == $t)] | length' "$negatives")"
  if [ "$trap_n" -ge 1 ]; then
    ok "authoring trap ${trap_id} is covered by ${trap_n} case(s)"
  else
    bad "authoring trap ${trap_id} has no case"
  fi
done

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
