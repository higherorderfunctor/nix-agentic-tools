#!/usr/bin/env bash
#
# Validate a Kiro CLI v3 workflow definition against the contract in
# `contract.jq`, WITHOUT a live session.
#
# The engine's own `validate_workflow` tool is unreachable until a
# workflow-enabled session exists, and creating one means seeding a persisted
# session with a definition already in hand — so the tool cannot vet the thing
# you need in order to have anything worth seeding. `contract.jq` re-implements
# the contract from a bundle read so a definition can be trusted before the
# operator launches anything. Read its header for what that does and does not
# buy; in particular several rules are deliberately STRICTER than the engine.
#
# usage: validate-workflow.sh [--json] [--strict] <file.workflow.json>...
#
#   --json    emit one JSON object per input file (JSONL):
#               {"file": <path>, "diagnostics": [ {severity, code, where, message} ]}
#             This is the machine-readable surface; self-test-validate.sh
#             consumes it and matches on `code`, so a reworded message never
#             breaks the tests.
#   --strict  treat warnings as failures. Warnings flag choices that are legal
#             but that the records show behave contrary to intuition
#             (`joinPolicy: "all"`, `onMaxIterations: "pause"`), so a fixture
#             meant to be run unattended should pass --strict.
#
# exit 0  no errors (and, under --strict, no warnings) in any input file
# exit 1  at least one file failed
# exit 2  usage error
#
# READ-ONLY. Touches no Kiro state, starts no session, needs no network.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
contract="$here/contract.jq"

emit_json=0
strict=0
declare -a files=()

usage() {
  echo "usage: $(basename "$0") [--json] [--strict] <file.workflow.json>..." >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
  --json)
    emit_json=1
    shift
    ;;
  --strict)
    strict=1
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  --)
    shift
    files+=("$@")
    break
    ;;
  -*)
    echo "unknown option: $1" >&2
    usage
    exit 2
    ;;
  *)
    files+=("$1")
    shift
    ;;
  esac
done

if [ "${#files[@]}" -eq 0 ]; then
  echo "no input files" >&2
  usage
  exit 2
fi

if [ ! -f "$contract" ]; then
  echo "contract program missing at ${contract}" >&2
  exit 2
fi

# A file that does not parse never reaches jq's filter, so this one diagnostic
# is synthesized here rather than in contract.jq. It is shaped identically to
# the ones the filter emits so consumers need no special case.
parse_error_diagnostic() {
  local detail="$1"
  jq -n --arg detail "$detail" '
    [{
      severity: "error",
      code: "E-JSON-PARSE",
      where: "workflow",
      message: ("the file is not valid JSON: " + $detail),
      basis: "mechanical"
    }]'
}

# Same reasoning as the parse error, one step earlier: a file that is not there
# never reaches the parse gate either, so its diagnostic is synthesized here and
# shaped identically to every other one.
# The detail is passed in because `[ ! -f ]` is true for two different things:
# a path that is absent, and a path that exists but is not a regular file (a
# directory being the one an operator actually hits, via a stray glob or a
# tab-completed directory name). Reporting "no such file" for a directory sends
# the reader looking for a typo in a path that is sitting right there.
#
# One CODE for both, deliberately. The code names the class the caller must
# branch on -- "this could not be read as a workflow at all" -- and this
# directory's own rule is to match on `code`, never on `message`. The message is
# where the human-facing distinction belongs, and splitting the code would also
# oblige a second registry entry and a second negative case for a difference no
# consumer acts on.
missing_file_diagnostic() {
  local detail="$1"
  jq -n --arg detail "$detail" '
    [{
      severity: "error",
      code: "E-FILE-MISSING",
      where: "workflow",
      message: $detail,
      basis: "mechanical"
    }]'
}

overall=0

for file in "${files[@]}"; do
  # A missing file emits a DIAGNOSTIC rather than a bare stderr line. `--json`
  # promises one object per input file and a consumer maps its arguments onto
  # that stream positionally; skipping the emission broke that promise silently.
  # The run still failed, but the file that caused it was absent from the
  # output, so every later object was attributed to the wrong argument -- a
  # worse outcome than the missing file itself, and invisible.
  if [ ! -f "$file" ]; then
    if [ -e "$file" ]; then
      diagnostics="$(missing_file_diagnostic "exists but is not a regular file")"
    else
      diagnostics="$(missing_file_diagnostic "no such file")"
    fi
  else
    # `jq empty` is the parse gate: it reads the document and produces nothing, so
    # a failure here is a syntax failure and its stderr is the diagnostic detail.
    parse_stderr=""
    if ! parse_stderr="$(jq empty "$file" 2>&1)"; then
      diagnostics="$(parse_error_diagnostic "$(printf '%s' "$parse_stderr" | tr '\n' ' ')")"
    else
      diagnostics="$(jq -f "$contract" "$file")"
    fi
  fi

  errors="$(printf '%s' "$diagnostics" | jq '[.[] | select(.severity == "error")] | length')"
  warnings="$(printf '%s' "$diagnostics" | jq '[.[] | select(.severity == "warn")] | length')"

  if [ "$emit_json" -eq 1 ]; then
    printf '%s' "$diagnostics" |
      jq -c --arg file "$file" '{file: $file, diagnostics: .}'
  else
    if [ "$errors" -eq 0 ] && [ "$warnings" -eq 0 ]; then
      printf '%s: PASS (0 errors, 0 warnings)\n' "$file"
    else
      # The verdict must be computed from the SAME condition as the exit code
      # below, `--strict` included. Reading only `errors` printed
      # "PASS with warnings" on a strict run that then exited non-zero: a human
      # reading the output believed PASS, a script reading `$?` believed
      # failure, and one run emitted both. That also contradicted this
      # directory's own claim that `--strict` is what proves the warning channel
      # reaches the exit code rather than being decorative.
      if [ "$errors" -ne 0 ]; then
        verdict=FAIL
      elif [ "$strict" -eq 1 ]; then
        verdict='FAIL (warnings are errors under --strict)'
      else
        verdict='PASS with warnings'
      fi
      printf '%s: %s\n' "$file" "$verdict"
      # `basis` is printed because it changes what the author should do: an
      # `engine` rejection will happen to them anyway, a `policy` one is this
      # harness being stricter than the engine on purpose (see contract.jq).
      printf '%s' "$diagnostics" |
        jq -r '.[] | "  " + (if .severity == "error" then "ERROR" else "WARN " end)
                   + " [" + .basis + "] " + .code + "  " + .where
                   + "\n      " + .message'
      printf '%s: %d error(s), %d warning(s)\n' "$file" "$errors" "$warnings"
    fi
  fi

  if [ "$errors" -ne 0 ]; then
    overall=1
  elif [ "$strict" -eq 1 ] && [ "$warnings" -ne 0 ]; then
    overall=1
  fi
done

exit "$overall"
