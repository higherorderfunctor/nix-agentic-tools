#!/usr/bin/env bash
# dev/scripts/resolve-recipe-file.test.sh — unit test for
# resolve_recipe_file. Pure bash + fixtures, no nix. Run directly:
#   bash dev/scripts/resolve-recipe-file.test.sh
#
# Exercises the resolver when a target has no source recipe or several.
# Keep one valid control here; update-targets-parity checks live mappings.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=dev/scripts/resolve-recipe-file.sh
source "$here/resolve-recipe-file.sh"

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/mcp-servers"

write_recipe() {
	local file="$1"
	shift
	{
		printf '%s\n' '{...}: let' '  rev = "83a768303839b9e125f6c286369a5d9cc26c666e";' '  src = fetchFromGitHub {'
		printf '    %s\n' "$@" 'inherit rev;' 'hash = "";'
		printf '%s\n' '  };' 'in {}'
	} >"$fixture/$file"
}

assert_resolution() {
	local label="$1" expected_status="$2" expected_stdout="$3" expected_stderr="${4-}"
	local output diagnostic status=0
	resolve_recipe_file "$context7_url" "$fixture" >"$fixture/stdout" 2>"$fixture/stderr" || status=$?
	output=$(<"$fixture/stdout")
	diagnostic=$(<"$fixture/stderr")
	if [[ $status != "$expected_status" || $output != "$expected_stdout" ||
		($# -eq 4 && $diagnostic != "$expected_stderr") ]]; then
		printf 'FAIL: %s (%s): expected status %s and stdout %q; got status %s, stdout %q, stderr %q\n' \
			"$label" "$context7_url" "$expected_status" "$expected_stdout" "$status" "$output" "$diagnostic" >&2
		if [[ $# -eq 4 ]]; then
			printf '  expected stderr %q\n' "$expected_stderr" >&2
		fi
		return 1
	fi
	printf 'ok: %s\n' "$label"
}

context7_url=https://github.com/upstash/context7.git
recipe=mcp-servers/context7-mcp.nix
no_match='resolve_recipe_file: expected exactly 1 recipe pinning upstash/context7, found 0: <none>'

# Keep the effect-mcp comment that fooled the old substring lookup. Test it
# before adding the real context7 recipe so a substring match cannot pass.
write_recipe mcp-servers/effect-mcp.nix \
	'# Pin pnpm_10 for the deps fetch and build. Mirrors context7-mcp.nix.' \
	'owner = "tim-smart";' 'repo = "effect-mcp";'

# Registry metadata names the exact upstream but has no inline revision.
# It must not become a fallback target when the source recipe is absent.
cat >"$fixture/mcp-servers/registry.nix" <<NIX
{
  update.targets.context7-mcp.git = "$context7_url";
}
NIX
assert_resolution 'neither a recipe comment nor an exact registry URL substitutes for a missing source recipe' 1 '' "$no_match"

write_recipe "$recipe" 'owner = "upstash";' 'repo = "context7";'
assert_resolution 'one matching source recipe resolves despite unrelated mentions' 0 "$fixture/$recipe"

cp "$fixture/$recipe" "$fixture/mcp-servers/context7-dup.nix"
assert_resolution 'two matching source recipes are rejected rather than picking the first' 1 '' \
	"resolve_recipe_file: expected exactly 1 recipe pinning upstash/context7, found 2: $fixture/mcp-servers/context7-dup.nix $fixture/$recipe"
