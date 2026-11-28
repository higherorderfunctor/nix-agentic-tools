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

create_baseline() {
	local baseline="$work/baseline"
	mkdir -p "$baseline/agents" "$baseline/hooks/bin"

	cat >"$baseline/agents/probe-baseline.md" <<'PROFILE'
---
description: Self-test baseline profile.
dispatchKind: sub-agent
---

Reply with exactly one line: BASELINE.
PROFILE

	cat >"$baseline/hooks/probe-baseline.json" <<'HOOKS_JSON'
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

	cat >"$baseline/hooks/bin/probe-baseline.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
cat >/dev/null
SCRIPT
	chmod +x "$baseline/hooks/bin/probe-baseline.sh"
}

reset_case() {
	rm -rf "$work/agents" "$work/hooks"
	cp -R "$work/baseline/agents" "$work/baseline/hooks" "$work"
}

run_linter() {
	local agents="${1:-$work/agents}" hooks="${2:-$work/hooks}" rc=0
	linter_out="$(bash "$linter" "$agents" "$hooks" 2>&1)" || rc=$?
	linter_rc="$rc"
}

report_bad() {
	printf 'not ok - %s\n' "$1"
	printf '%s\n' "$linter_out" | sed 's/^/        | /'
	failed=$((failed + 1))
}

expect_pass() {
	local label="$1" path
	shift
	run_linter
	if [ "$linter_rc" -ne 0 ]; then
		report_bad "ACCEPT $label (expected exit 0, got ${linter_rc})"
		return
	fi
	for path in "$@"; do
		if ! grep -Fxq "  $path" <<<"$linter_out"; then
			report_bad "ACCEPT $label (did not examine $path)"
			return
		fi
	done
	printf 'ok   ACCEPT %s\n' "$label"
	passed=$((passed + 1))
}

expect_finding() {
	local code="$1" path="$2" label="$3" finding
	run_linter
	finding="$(grep -F "FAIL $code $path: " <<<"$linter_out" || :)"
	if [ "$linter_rc" -eq 1 ] && [ -n "$finding" ]; then
		printf 'ok   REJECT %-34s %s\n' "$code" "$label"
		printf '            %s\n' "$finding"
		passed=$((passed + 1))
	else
		report_bad "REJECT $label (expected $code on $path; exit $linter_rc)"
	fi
}

expect_refusal() {
	local label="$1" reason="$2"
	run_linter "$3" "$4"
	if [ "$linter_rc" -eq 2 ] && grep -Fq "lint-probes: $reason" <<<"$linter_out"; then
		printf 'ok   REFUSE %s\n' "$label"
		passed=$((passed + 1))
	else
		report_bad "REFUSE $label (expected exit 2 and '$reason', got ${linter_rc})"
	fi
}

write_profile() {
	local path="$1"
	shift
	printf '%s\n' '---' "$@" '---' '' 'Body.' >"$work/agents/$path"
}

edit_baseline_hook() {
	local hook="$work/hooks/probe-baseline.json"
	jq "$@" "$hook" >"$hook.new"
	mv "$hook.new" "$hook"
}

edit_baseline_command() {
	edit_baseline_hook --arg command "\"\$KIRO_PROBE_BIN/$1\" $2" \
		".hooks[0].action.command = \$command"
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
	write_profile probe-shadow.md 'name: vibe' 'description: Shadows a builtin.'
}

mutate_dispatch_kind_invalid() {
	write_profile probe-bad-kind.md 'dispatchKind: subagent'
}

mutate_doc_file_in_agents_dir() {
	printf '%s\n' '# Agent probes' '' 'Prose, not a profile.' \
		>"$work/agents/README.md"
}

mutate_duplicate_effective_id() {
	write_profile probe-twin.md 'name: probe-baseline'
}

mutate_frontmatter_empty() {
	write_profile probe-empty-fm.md '# only a comment lives here'
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
	write_profile probe-hooks-flow.md 'hooks: {}'
}

mutate_hooks_object_md_mapping() {
	write_profile probe-hooks-map.md 'hooks:' '  onSave:' '    command: true'
}

mutate_json_cli_only_fields() {
	printf '%s\n' '{ "allowedTools": ["read_files"], "description": "CLI-only, unmarked." }' \
		>"$work/agents/probe-cli-only.json"
}

mutate_json_invalid() {
	printf '%s\n' '{ "description": "unterminated' >"$work/agents/probe-bad-json.json"
}

mutate_pseudo_boolean() {
	write_profile probe-pseudo-bool.md 'includePowers: yes'
}

mutate_pseudo_boolean_in_sequence() {
	write_profile probe-pseudo-seq.md 'hooks:' '  - no'
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
	edit_baseline_hook '.hooks[0].matcher = "[unclosed"'
}

mutate_hook_matcher_present() {
	edit_baseline_hook '.hooks[0].matcher = "read"'
}

mutate_hook_nested_json() {
	mkdir -p "$work/hooks/nested"
	cp "$work/hooks/probe-baseline.json" "$work/hooks/nested/probe-nested.json"
}

mutate_hook_schema_trigger() {
	edit_baseline_hook '.hooks[0].trigger = "onSessionStart"'
}

mutate_hook_script_missing() {
	edit_baseline_command probe-absent.sh baseline
}

mutate_hook_stderr_in_injecting_probe() {
	printf '%s\n' 'echo progress >&2' >>"$work/hooks/bin/probe-baseline.sh"
}

mutate_hook_symlink() {
	ln -s probe-baseline.json "$work/hooks/probe-linked.json"
}

mutate_hook_timeout_zero() {
	edit_baseline_hook '.hooks[0].timeout = 0'
}

# ---------------------------------------------------------------------------
# Near misses that must stay ACCEPTED.
# ---------------------------------------------------------------------------

allow_hooks_flow_array() {
	write_profile probe-hooks-array.md 'hooks: []'
}

allow_hooks_block_array() {
	write_profile probe-hooks-block.md 'hooks:' '  - name: inline'
}

allow_json_cli_only_with_permissions() {
	printf '%s\n' \
		'{ "allowedTools": ["read_files"], "permissions": { "rules": [] } }' \
		>"$work/agents/probe-marked.json"
}

allow_nested_agent_profile() {
	mkdir -p "$work/agents/workers"
	write_profile workers/drainer.md 'description: Nested profile; the agents loader recurses.'
}

allow_quoted_pseudo_boolean() {
	write_profile probe-quoted.md 'model: "yes"'
}

allow_strict_boolean_true() {
	write_profile probe-real-bool.md 'includePowers: true' 'includeMcpJson: false'
}

allow_url_in_command() {
	edit_baseline_command probe-baseline.sh https://example.invalid/x
}

# outcome:mutation-function:path:label. A rejection requires both the finding
# code and its path; an acceptance requires proof that the linter read the path.
cases=(
	# Rejections, sorted by finding code.
	"agent-broken-symlink:mutate_broken_symlink:probe-dangling.md:a dangling profile symlink"
	"agent-builtin-id-collision:mutate_builtin_id_filename:spec.md:spec.md takes a builtin mode id"
	"agent-builtin-id-collision:mutate_builtin_id_name_override:probe-shadow.md:name: vibe overrides the filename"
	"agent-dispatch-kind-invalid:mutate_dispatch_kind_invalid:probe-bad-kind.md:dispatchKind outside the enum"
	"agent-doc-file-in-agents-dir:mutate_doc_file_in_agents_dir:README.md:a README beside the profiles"
	"agent-duplicate-effective-id:mutate_duplicate_effective_id:probe-twin.md:two profiles, one effective id"
	"agent-frontmatter-empty:mutate_frontmatter_empty:probe-empty-fm.md:comment-only front matter"
	"agent-frontmatter-missing:mutate_frontmatter_missing:probe-no-fm.md:no front-matter fence"
	"agent-frontmatter-unterminated:mutate_frontmatter_unterminated:probe-unterminated.md:front matter never closed"
	"agent-hooks-object-shaped:mutate_hooks_object_json:probe-hooks-object.json:JSON profile with hooks: {}"
	"agent-hooks-object-shaped:mutate_hooks_object_md_flow:probe-hooks-flow.md:front matter with hooks: {}"
	"agent-hooks-object-shaped:mutate_hooks_object_md_mapping:probe-hooks-map.md:front matter with a hooks mapping"
	"agent-json-cli-only-fields:mutate_json_cli_only_fields:probe-cli-only.json:allowedTools with no permissions"
	"agent-json-invalid:mutate_json_invalid:probe-bad-json.json:malformed JSON profile"
	"agent-pseudo-boolean:mutate_pseudo_boolean:probe-pseudo-bool.md:includePowers: yes"
	"agent-pseudo-boolean:mutate_pseudo_boolean_in_sequence:probe-pseudo-seq.md:a bare no in a sequence"
	"hook-json-comment:mutate_hook_json_comment:probe-commented.json:a // comment in a hook document"
	"hook-json-trailing-comma:mutate_hook_json_trailing_comma:probe-trailing-comma.json:a trailing comma in a hook document"
	"hook-matcher-invalid:mutate_hook_matcher_invalid:probe-baseline.json:a matcher that does not compile"
	"hook-matcher-present:mutate_hook_matcher_present:probe-baseline.json:a matcher at all"
	"hook-nested-json:mutate_hook_nested_json:nested/probe-nested.json:a hook .json in a subdirectory"
	"hook-schema-invalid:mutate_hook_schema_trigger:probe-baseline.json:a trigger outside the canonical 11"
	"hook-script-missing:mutate_hook_script_missing:probe-baseline.json:a command pointing at no script"
	"hook-stderr-in-injecting-probe:mutate_hook_stderr_in_injecting_probe:probe-baseline.json:stderr from a SessionStart probe"
	"hook-symlink:mutate_hook_symlink:probe-linked.json:a symlinked hook file"
	"hook-timeout-zero:mutate_hook_timeout_zero:probe-baseline.json:timeout: 0 means no timeout at all"

	# Acceptances, sorted by function name.
	"accept:allow_hooks_block_array:probe-hooks-block.md:a hooks block sequence is the v3 shape"
	"accept:allow_hooks_flow_array:probe-hooks-array.md:hooks: [] is the v3 shape"
	"accept:allow_json_cli_only_with_permissions:probe-marked.json:allowedTools WITH permissions is marked, not skipped"
	"accept:allow_nested_agent_profile:workers/drainer.md:a profile in a subdirectory (the agents loader recurses)"
	'accept:allow_quoted_pseudo_boolean:probe-quoted.md:a quoted "yes" is a string on purpose'
	"accept:allow_strict_boolean_true:probe-real-bool.md:literal true and false in boolean fields"
	"accept:allow_url_in_command:probe-baseline.json:a // inside a command string is not a JSON comment"
)

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

echo '--- baseline control -------------------------------------------------'
# Every case starts from a fresh copy of this same validated template, so a
# rejection cannot be credited to unrelated baseline findings.
create_baseline
reset_case
expect_pass 'the unchanged baseline fixture' probe-baseline.md probe-baseline.json

echo
echo '--- REJECT and ACCEPT cases -------------------------------------------'
for entry in "${cases[@]}"; do
	outcome="${entry%%:*}"
	rest="${entry#*:}"
	fn="${rest%%:*}"
	rest="${rest#*:}"
	path="${rest%%:*}"
	label="${rest#*:}"
	reset_case
	"$fn"
	if [ "$outcome" = accept ]; then
		expect_pass "$label" "$path"
	else
		expect_finding "$outcome" "$path" "$label"
	fi
done

echo
echo '--- REFUSE cases -----------------------------------------------------'
reset_case
rm -f "$work/agents/probe-baseline.md" "$work/hooks/probe-baseline.json"
expect_refusal 'empty directories are not a pass' 'examined nothing' "$work/agents" "$work/hooks"
reset_case
expect_refusal 'a missing agents directory' "no agents directory at $work/absent-agents" \
	"$work/absent-agents" "$work/hooks"
expect_refusal 'a missing hooks directory' "no hooks directory at $work/absent-hooks" \
	"$work/agents" "$work/absent-hooks"

echo
printf 'cases passed: %d\n' "$passed"
printf 'cases failed: %d\n' "$failed"

if [ "$failed" -ne 0 ]; then
	printf 'FAIL: %d case(s) did not behave as specified\n' "$failed" >&2
	exit 1
fi
echo 'PASS'
