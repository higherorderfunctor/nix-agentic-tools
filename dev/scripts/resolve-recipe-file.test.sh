#!/usr/bin/env bash
# dev/scripts/resolve-recipe-file.test.sh — unit test for
# resolve_recipe_file. Pure bash + fixtures, no nix. Run directly:
#   bash dev/scripts/resolve-recipe-file.test.sh
#
# Checks that a context7 mention in an effect-mcp comment does not resolve
# and that the resolver requires exactly one matching recipe.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=dev/scripts/resolve-recipe-file.sh
source "$here/resolve-recipe-file.sh"

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/mcp-servers"

write_recipe() {
	local file="$1" fetcher="$2"
	shift 2
	{
		printf '%s\n' '{...}: let' '  rev = "83a768303839b9e125f6c286369a5d9cc26c666e";' "  src = $fetcher {"
		printf '    %s\n' "$@" 'inherit rev;' 'hash = "";'
		printf '%s\n' '  };' 'in {}'
	} >"$fixture/$file"
}

assert_rejected() {
	local label="$1" url="$2" expected="$3" diagnostic status=0
	resolve_recipe_file "$url" "$fixture" >"$fixture/stdout" 2>"$fixture/stderr" || status=$?
	diagnostic=$(<"$fixture/stderr")
	if [[ $status != 1 || -s "$fixture/stdout" || $diagnostic != "$expected" ]]; then
		printf 'FAIL: %s (%s): expected status 1, empty stdout, stderr %q; got status %s, stdout %q, stderr %q\n' \
			"$label" "$url" "$expected" "$status" "$(<"$fixture/stdout")" "$diagnostic" >&2
		return 1
	fi
	printf 'ok: %s\n' "$label"
}

# The old substring lookup picked up this comment in the effect-mcp recipe.
# Make it the only context7 mention first: a substring resolver cannot pick
# the right file by chance when no actual context7 recipe exists yet.
write_recipe mcp-servers/effect-mcp.nix fetchFromGitHub \
	'# Pin pnpm_10 for the deps fetch and build. Mirrors context7-mcp.nix.' \
	'owner = "tim-smart";' 'repo = "effect-mcp";'
context7_url=https://github.com/upstash/context7.git
assert_rejected 'context7 mentioned only in an unrelated recipe comment' "$context7_url" \
	'resolve_recipe_file: expected exactly 1 recipe pinning upstash/context7, found 0: <none>'

write_recipe mcp-servers/context7-mcp.nix fetchFromGitHub 'owner = "upstash";' 'repo = "context7";'
write_recipe kiro-gateway.nix fetchgit 'url = "https://github.com/jwadow/kiro-gateway.git";'

# The aggregator mentions every recipe but is not itself a recipe.
cat >"$fixture/default.nix" <<'NIX'
{...}: {
  context7-mcp = import ./mcp-servers/context7-mcp.nix {};
  effect-mcp = import ./mcp-servers/effect-mcp.nix {};
  kiro-gateway = import ./kiro-gateway.nix {};
}
NIX

# Registry metadata names the exact upstream but has no inline revision.
cat >"$fixture/mcp-servers/registry.nix" <<NIX
{
  update.targets.context7-mcp.git = "$context7_url";
}
NIX

while read -r url path; do
	expected="$fixture/$path"
	if ! got=$(resolve_recipe_file "$url" "$fixture") || [[ $got != "$expected" ]]; then
		printf 'FAIL: %s: expected %q, got %q\n' "$url" "$expected" "$got" >&2
		exit 1
	fi
	printf 'ok: %s resolves to %s\n' "$url" "$path"
done <<ROWS
$context7_url mcp-servers/context7-mcp.nix
https://github.com/jwadow/kiro-gateway.git kiro-gateway.nix
https://github.com/tim-smart/effect-mcp.git mcp-servers/effect-mcp.nix
ROWS

assert_rejected 'missing mapping' 'https://github.com/nobody/does-not-exist.git' \
	'resolve_recipe_file: expected exactly 1 recipe pinning nobody/does-not-exist, found 0: <none>'

cp "$fixture/mcp-servers/context7-mcp.nix" "$fixture/mcp-servers/context7-dup.nix"
assert_rejected 'ambiguous mapping' "$context7_url" \
	"resolve_recipe_file: expected exactly 1 recipe pinning upstash/context7, found 2: $fixture/mcp-servers/context7-dup.nix $fixture/mcp-servers/context7-mcp.nix"
