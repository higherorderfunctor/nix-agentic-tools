#!/usr/bin/env bash
# Tier-1b contract-test harness (PROTOTYPE — not wired into checks/).
#
# For each fixture under fixtures/**/*.json: pipe its documented `stdin` payload to the named
# hook-under-test, capture stdout+stderr+exit, and assert the fixture's `expect` block. This is
# the hermetic, stub-free analogue of checks/validate-at-stop.nix generalised to every event's
# documented I/O contract (assessment §9 Tier-1b). Deterministic: no network, no auth, no CLI.
#
# Requires: bash, jq, coreutils (grep/mktemp). The .nix wrapper (contract-test.nix) supplies these
# via nativeBuildInputs and shellchecks every script first.
#
# Usage: bash run-contract-tests.sh [-v]     ( -v prints PASS lines too )
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

verbose=0
if [ "${1:-}" = "-v" ]; then verbose=1; fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hooks_dir="$here/hooks-under-test"
fixtures_dir="$here/fixtures"

tmproot="$(mktemp -d)"
trap 'rm -rf "$tmproot"' EXIT

pass=0
fail=0

run_fixture() {
  local fx="$1"
  local rel="${fx#"$fixtures_dir"/}"

  local hook hook_path stdin
  hook="$(jq -r '.hook' "$fx")"
  hook_path="$hooks_dir/$hook"
  if [ ! -f "$hook_path" ]; then
    echo "FAIL [$rel]: hook not found: $hook"
    fail=$((fail + 1))
    return
  fi
  stdin="$(jq -c '.stdin' "$fx")"

  # Optional setup: create a temp cwd populated with marker files, splice into stdin.cwd.
  if jq -e 'has("setup")' "$fx" >/dev/null; then
    local tmp f
    tmp="$(mktemp -d "$tmproot/cwd.XXXXXX")"
    while IFS= read -r f; do
      if [ -n "$f" ]; then : >"$tmp/$f"; fi
    done < <(jq -r '.setup.cwdFiles[]?' "$fx")
    stdin="$(jq -c --arg cwd "$tmp" '.cwd = $cwd' <<<"$stdin")"
  fi

  # Run the hook with the payload on stdin; capture stdout, stderr, exit code.
  local out err rc errfile
  errfile="$(mktemp "$tmproot/err.XXXXXX")"
  if out="$(printf '%s' "$stdin" | bash "$hook_path" 2>"$errfile")"; then rc=0; else rc=$?; fi
  err="$(cat "$errfile")"

  local ok=1 msg=""

  # exit code
  local exp_exit
  exp_exit="$(jq -r '.expect.exit // 0' "$fx")"
  [ "$rc" -eq "$exp_exit" ] || {
    ok=0
    msg+=" exit=$rc≠$exp_exit;"
  }

  # stdout emptiness
  if [ "$(jq -r '.expect.stdoutEmpty // false' "$fx")" = "true" ]; then
    [ -z "$out" ] || {
      ok=0
      msg+=" stdout expected empty, got '${out:0:40}';"
    }
  fi

  # stderr substring
  local sc
  sc="$(jq -r '.expect.stderrContains // empty' "$fx")"
  if [ -n "$sc" ]; then
    printf '%s' "$err" | grep -qF -- "$sc" || {
      ok=0
      msg+=" stderr lacks '$sc';"
    }
  fi

  # JSON stdout assertions
  local n
  n="$(jq -r '(.expect.jsonAsserts // []) | length' "$fx")"
  if [ "$n" -gt 0 ]; then
    if ! printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
      ok=0
      msg+=" stdout is not valid JSON;"
    else
      local i path
      for ((i = 0; i < n; i++)); do
        path="$(jq -r ".expect.jsonAsserts[$i].path" "$fx")"
        if jq -e ".expect.jsonAsserts[$i] | has(\"eq\")" "$fx" >/dev/null; then
          local eqv actual
          eqv="$(jq -r ".expect.jsonAsserts[$i].eq" "$fx")"
          actual="$(printf '%s' "$out" | jq -r "$path // empty")"
          [ "$actual" = "$eqv" ] || {
            ok=0
            msg+=" $path='$actual'≠'$eqv';"
          }
        elif [ "$(jq -r ".expect.jsonAsserts[$i].present // false" "$fx")" = "true" ]; then
          printf '%s' "$out" | jq -e "$path != null" >/dev/null || {
            ok=0
            msg+=" $path missing;"
          }
        elif [ "$(jq -r ".expect.jsonAsserts[$i].absent // false" "$fx")" = "true" ]; then
          printf '%s' "$out" | jq -e "$path == null" >/dev/null || {
            ok=0
            msg+=" $path should be absent;"
          }
        fi
      done
    fi
  fi

  if [ "$ok" -eq 1 ]; then
    pass=$((pass + 1))
    if [ "$verbose" -eq 1 ]; then echo "PASS [$rel]"; fi
  else
    echo "FAIL [$rel]:$msg"
    fail=$((fail + 1))
  fi
}

mapfile -d '' fixtures < <(find "$fixtures_dir" -type f -name '*.json' -print0 | sort -z)
for fx in "${fixtures[@]}"; do
  run_fixture "$fx"
done

echo "tier1b contract tests: $pass passed, $fail failed (${#fixtures[@]} fixtures)"
[ "$fail" -eq 0 ]
