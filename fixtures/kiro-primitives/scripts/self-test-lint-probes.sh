#!/usr/bin/env bash
#
# Self-test for lint-probes.sh.
#
# Three kinds of case, and the second kind is the one that makes this worth
# running:
#
#   REJECT  a baseline that PASSES, plus one mutation, must produce a named
#           finding. The baseline pass is the positive control: without it, a
#           rejection could come from anything in the fixture rather than from
#           the mutation.
#   ACCEPT  a NEAR MISS that must stay clean. Each of these is the legal
#           neighbour of a rule above - `timeout: 60` next to `timeout: 0`,
#           `allowedTools` WITH `permissions`, a quoted "yes". A rule that
#           degenerated into "is this field present" would still pass every
#           REJECT case and would fail here. This is where a rule that is right
#           for the wrong reason gets caught.
#   REFUSE  the linter must exit 2 - could not run - rather than 0, when there
#           is nothing to examine or a directory is missing.
#
# Writes only inside its own mktemp directory.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
linter="$here/lint-probes.sh"
[ -x "$linter" ] || {
  echo "self-test: ${linter} is not executable" >&2
  exit 2
}

work="$(mktemp -d "${TMPDIR:-/tmp}/kiro-lint-probes-self_test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

passed=0
failed=0
linter_rc=0
linter_out=""

# ---------------------------------------------------------------------------
# Baseline fixture: minimal, valid, and deliberately boring.
# ---------------------------------------------------------------------------

reset_case() {
  rm -rf "$work/agents" "$work/hooks"
  mkdir -p "$work/agents" "$work/hooks/bin"

  cat >"$work/agents/probe-baseline.md" <<'PROFILE'
---
description: Self-test baseline profile.
dispatchKind: sub-agent
---

Reply with exactly one line: BASELINE.
PROFILE

  cat >"$work/hooks/probe-baseline.json" <<'HOOKS_JSON'
{
  "hooks": [
    {
      "action": {
        "command": "\"$KIRO_PROBE_BIN/probe-baseline.sh\" baseline",
        "type": "command"
      },
      "enabled": true,
      "name": "probe-baseline",
      "timeout": 10,
      "trigger": "SessionStart"
    }
  ],
  "version": "v1"
}
HOOKS_JSON

  cat >"$work/hooks/bin/probe-baseline.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
cat >/dev/null
SCRIPT
  chmod +x "$work/hooks/bin/probe-baseline.sh"
}

run_linter() {
  local rc=0
  linter_out="$(bash "$linter" "$work/agents" "$work/hooks" 2>&1)" || rc=$?
  linter_rc="$rc"
}

report_bad() {
  printf 'not ok - %s\n' "$1"
  printf '%s\n' "$linter_out" | sed 's/^/        | /'
  failed=$((failed + 1))
}

expect_pass() {
  run_linter
  if [ "$linter_rc" -eq 0 ]; then
    printf 'ok   ACCEPT %s\n' "$1"
    passed=$((passed + 1))
  else
    report_bad "ACCEPT $1 (expected exit 0, got ${linter_rc})"
  fi
}

expect_finding() {
  local code="$1" label="$2"
  run_linter
  if [ "$linter_rc" -eq 1 ] && grep -q "^FAIL ${code} " <<<"$linter_out"; then
    printf 'ok   REJECT %-34s %s\n' "$code" "$label"
    printf '            %s\n' "$(grep -m1 "^FAIL ${code} " <<<"$linter_out")"
    passed=$((passed + 1))
  else
    report_bad "REJECT ${code} ${label} (exit ${linter_rc})"
  fi
}

expect_refusal() {
  local label="$1" dir_a="$2" dir_b="$3" rc=0
  linter_out="$(bash "$linter" "$dir_a" "$dir_b" 2>&1)" || rc=$?
  if [ "$rc" -eq 2 ]; then
    printf 'ok   REFUSE %s\n' "$label"
    passed=$((passed + 1))
  else
    linter_rc="$rc"
    report_bad "REFUSE ${label} (expected exit 2, got ${rc})"
  fi
}

# ---------------------------------------------------------------------------
# Mutations that must be REJECTED, one per trap.
# ---------------------------------------------------------------------------

mutate_broken_symlink() {
  ln -s nowhere.md "$work/agents/probe-dangling.md"
}

mutate_builtin_id_filename() {
  mv "$work/agents/probe-baseline.md" "$work/agents/spec.md"
}

mutate_builtin_id_name_override() {
  printf '%s\n' '---' 'name: vibe' 'description: Shadows a builtin.' '---' '' 'Body.' \
    >"$work/agents/probe-shadow.md"
}

mutate_dispatch_kind_invalid() {
  printf '%s\n' '---' 'dispatchKind: subagent' '---' '' 'Body.' \
    >"$work/agents/probe-bad-kind.md"
}

mutate_doc_file_in_agents_dir() {
  printf '%s\n' '# Agent probes' '' 'Prose, not a profile.' \
    >"$work/agents/README.md"
}

mutate_duplicate_effective_id() {
  printf '%s\n' '---' 'name: probe-baseline' '---' '' 'Body.' \
    >"$work/agents/probe-twin.md"
}

mutate_frontmatter_empty() {
  printf '%s\n' '---' '# only a comment lives here' '---' '' 'Body.' \
    >"$work/agents/probe-empty-fm.md"
}

mutate_frontmatter_missing() {
  printf '%s\n' '# No front matter at all' '' 'Body.' \
    >"$work/agents/probe-no-fm.md"
}

mutate_frontmatter_unterminated() {
  printf '%s\n' '---' 'description: Never closed.' '' 'Body.' \
    >"$work/agents/probe-unterminated.md"
}

mutate_hooks_object_json() {
  printf '%s\n' '{ "description": "v2 shape", "hooks": {}, "permissions": { "rules": [] } }' \
    >"$work/agents/probe-hooks-object.json"
}

mutate_hooks_object_md_flow() {
  printf '%s\n' '---' 'hooks: {}' '---' '' 'Body.' \
    >"$work/agents/probe-hooks-flow.md"
}

mutate_hooks_object_md_mapping() {
  printf '%s\n' '---' 'hooks:' '  onSave:' '    command: true' '---' '' 'Body.' \
    >"$work/agents/probe-hooks-map.md"
}

mutate_json_cli_only_fields() {
  printf '%s\n' '{ "allowedTools": ["read_files"], "description": "CLI-only, unmarked." }' \
    >"$work/agents/probe-cli-only.json"
}

mutate_json_invalid() {
  printf '%s\n' '{ "description": "unterminated' >"$work/agents/probe-bad-json.json"
}

mutate_pseudo_boolean() {
  printf '%s\n' '---' 'includePowers: yes' '---' '' 'Body.' \
    >"$work/agents/probe-pseudo-bool.md"
}

mutate_pseudo_boolean_in_sequence() {
  printf '%s\n' '---' 'hooks:' '  - no' '---' '' 'Body.' \
    >"$work/agents/probe-pseudo-seq.md"
}

mutate_hook_json_comment() {
  printf '%s\n' '{' '  // a comment' '  "version": "v1",' '  "hooks": []' '}' \
    >"$work/hooks/probe-commented.json"
}

mutate_hook_json_trailing_comma() {
  printf '%s\n' '{' '  "version": "v1",' '  "hooks": [],' '}' \
    >"$work/hooks/probe-trailing-comma.json"
}

mutate_hook_matcher_invalid() {
  jq '.hooks[0].matcher = "[unclosed"' "$work/hooks/probe-baseline.json" \
    >"$work/hooks/probe-baseline.json.new"
  mv "$work/hooks/probe-baseline.json.new" "$work/hooks/probe-baseline.json"
}

mutate_hook_matcher_present() {
  jq '.hooks[0].matcher = "read"' "$work/hooks/probe-baseline.json" \
    >"$work/hooks/probe-baseline.json.new"
  mv "$work/hooks/probe-baseline.json.new" "$work/hooks/probe-baseline.json"
}

mutate_hook_nested_json() {
  mkdir -p "$work/hooks/nested"
  cp "$work/hooks/probe-baseline.json" "$work/hooks/nested/probe-nested.json"
}

mutate_hook_schema_trigger() {
  jq '.hooks[0].trigger = "onSessionStart"' "$work/hooks/probe-baseline.json" \
    >"$work/hooks/probe-baseline.json.new"
  mv "$work/hooks/probe-baseline.json.new" "$work/hooks/probe-baseline.json"
}

mutate_hook_script_missing() {
  jq '.hooks[0].action.command = "\"$KIRO_PROBE_BIN/probe-absent.sh\" baseline"' \
    "$work/hooks/probe-baseline.json" >"$work/hooks/probe-baseline.json.new"
  mv "$work/hooks/probe-baseline.json.new" "$work/hooks/probe-baseline.json"
}

mutate_hook_stderr_in_injecting_probe() {
  printf '%s\n' 'echo progress >&2' >>"$work/hooks/bin/probe-baseline.sh"
}

mutate_hook_symlink() {
  ln -s probe-baseline.json "$work/hooks/probe-linked.json"
}

mutate_hook_timeout_zero() {
  jq '.hooks[0].timeout = 0' "$work/hooks/probe-baseline.json" \
    >"$work/hooks/probe-baseline.json.new"
  mv "$work/hooks/probe-baseline.json.new" "$work/hooks/probe-baseline.json"
}

# code:mutation-function:label, sorted by code.
reject_cases=(
  "agent-broken-symlink:mutate_broken_symlink:a dangling profile symlink"
  "agent-builtin-id-collision:mutate_builtin_id_filename:spec.md takes a builtin mode id"
  "agent-builtin-id-collision:mutate_builtin_id_name_override:name: vibe overrides the filename"
  "agent-dispatch-kind-invalid:mutate_dispatch_kind_invalid:dispatchKind outside the enum"
  "agent-doc-file-in-agents-dir:mutate_doc_file_in_agents_dir:a README beside the profiles"
  "agent-duplicate-effective-id:mutate_duplicate_effective_id:two profiles, one effective id"
  "agent-frontmatter-empty:mutate_frontmatter_empty:comment-only front matter"
  "agent-frontmatter-missing:mutate_frontmatter_missing:no front-matter fence"
  "agent-frontmatter-unterminated:mutate_frontmatter_unterminated:front matter never closed"
  "agent-hooks-object-shaped:mutate_hooks_object_json:JSON profile with hooks: {}"
  "agent-hooks-object-shaped:mutate_hooks_object_md_flow:front matter with hooks: {}"
  "agent-hooks-object-shaped:mutate_hooks_object_md_mapping:front matter with a hooks mapping"
  "agent-json-cli-only-fields:mutate_json_cli_only_fields:allowedTools with no permissions"
  "agent-json-invalid:mutate_json_invalid:malformed JSON profile"
  "agent-pseudo-boolean:mutate_pseudo_boolean:includePowers: yes"
  "agent-pseudo-boolean:mutate_pseudo_boolean_in_sequence:a bare no in a sequence"
  "hook-json-comment:mutate_hook_json_comment:a // comment in a hook document"
  "hook-json-trailing-comma:mutate_hook_json_trailing_comma:a trailing comma in a hook document"
  "hook-matcher-invalid:mutate_hook_matcher_invalid:a matcher that does not compile"
  "hook-matcher-present:mutate_hook_matcher_present:a matcher at all"
  "hook-nested-json:mutate_hook_nested_json:a hook .json in a subdirectory"
  "hook-schema-invalid:mutate_hook_schema_trigger:a trigger outside the canonical 11"
  "hook-script-missing:mutate_hook_script_missing:a command pointing at no script"
  "hook-stderr-in-injecting-probe:mutate_hook_stderr_in_injecting_probe:stderr from a SessionStart probe"
  "hook-symlink:mutate_hook_symlink:a symlinked hook file"
  "hook-timeout-zero:mutate_hook_timeout_zero:timeout: 0 means no timeout at all"
)

# ---------------------------------------------------------------------------
# Near misses that must stay ACCEPTED.
# ---------------------------------------------------------------------------

allow_hooks_flow_array() {
  printf '%s\n' '---' 'hooks: []' '---' '' 'Body.' \
    >"$work/agents/probe-hooks-array.md"
}

allow_hooks_block_array() {
  printf '%s\n' '---' 'hooks:' '  - name: inline' '---' '' 'Body.' \
    >"$work/agents/probe-hooks-block.md"
}

allow_json_cli_only_with_permissions() {
  printf '%s\n' \
    '{ "allowedTools": ["read_files"], "permissions": { "rules": [] } }' \
    >"$work/agents/probe-marked.json"
}

allow_nested_agent_profile() {
  mkdir -p "$work/agents/workers"
  printf '%s\n' '---' 'description: Nested profile; the agents loader recurses.' '---' '' 'Body.' \
    >"$work/agents/workers/drainer.md"
}

allow_quoted_pseudo_boolean() {
  printf '%s\n' '---' 'model: "yes"' '---' '' 'Body.' \
    >"$work/agents/probe-quoted.md"
}

allow_strict_boolean_true() {
  printf '%s\n' '---' 'includePowers: true' 'includeMcpJson: false' '---' '' 'Body.' \
    >"$work/agents/probe-real-bool.md"
}

allow_timeout_nonzero() {
  jq '.hooks[0].timeout = 60' "$work/hooks/probe-baseline.json" \
    >"$work/hooks/probe-baseline.json.new"
  mv "$work/hooks/probe-baseline.json.new" "$work/hooks/probe-baseline.json"
}

allow_url_in_command() {
  jq '.hooks[0].action.command = "\"$KIRO_PROBE_BIN/probe-baseline.sh\" https://example.invalid/x"' \
    "$work/hooks/probe-baseline.json" >"$work/hooks/probe-baseline.json.new"
  mv "$work/hooks/probe-baseline.json.new" "$work/hooks/probe-baseline.json"
}

# mutation-function:label, sorted by function name.
accept_cases=(
  "allow_hooks_block_array:a hooks block sequence is the v3 shape"
  "allow_hooks_flow_array:hooks: [] is the v3 shape"
  "allow_json_cli_only_with_permissions:allowedTools WITH permissions is marked, not skipped"
  "allow_nested_agent_profile:a profile in a subdirectory (the agents loader recurses)"
  'allow_quoted_pseudo_boolean:a quoted "yes" is a string on purpose'
  "allow_strict_boolean_true:literal true and false in boolean fields"
  "allow_timeout_nonzero:timeout: 60 is not timeout: 0"
  "allow_url_in_command:a // inside a command string is not a JSON comment"
)

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

echo '--- baseline control -------------------------------------------------'
reset_case
expect_pass 'the unchanged baseline fixture'

echo
echo '--- REJECT cases -----------------------------------------------------'
for entry in "${reject_cases[@]}"; do
  code="${entry%%:*}"
  rest="${entry#*:}"
  fn="${rest%%:*}"
  label="${rest#*:}"
  reset_case
  expect_pass "baseline before ${fn}"
  "$fn"
  expect_finding "$code" "$label"
done

echo
echo '--- ACCEPT cases (near misses) ---------------------------------------'
for entry in "${accept_cases[@]}"; do
  fn="${entry%%:*}"
  label="${entry#*:}"
  reset_case
  "$fn"
  expect_pass "$label"
done

echo
echo '--- REFUSE cases -----------------------------------------------------'
reset_case
rm -f "$work/agents/probe-baseline.md" "$work/hooks/probe-baseline.json"
expect_refusal 'empty directories are not a pass' "$work/agents" "$work/hooks"
reset_case
expect_refusal 'a missing agents directory' "$work/absent-agents" "$work/hooks"
expect_refusal 'a missing hooks directory' "$work/agents" "$work/absent-hooks"

echo
printf 'cases passed: %d\n' "$passed"
printf 'cases failed: %d\n' "$failed"

# Every REJECT case contributes two assertions (baseline pass + finding), every
# ACCEPT one, plus one baseline control and three refusals.
expected=$((2 * ${#reject_cases[@]} + ${#accept_cases[@]} + 1 + 3))
if [ "$((passed + failed))" -ne "$expected" ]; then
  printf 'FAIL: ran %d assertions, expected %d - the case tables and the runner disagree\n' \
    "$((passed + failed))" "$expected" >&2
  exit 1
fi
if [ "$passed" -eq 0 ]; then
  echo 'FAIL: no assertions ran' >&2
  exit 1
fi
if [ "$failed" -ne 0 ]; then
  printf 'FAIL: %d case(s) did not behave as specified\n' "$failed" >&2
  exit 1
fi
echo 'PASS'
