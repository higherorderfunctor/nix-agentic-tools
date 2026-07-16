#!/usr/bin/env bash
# dev/scripts/resolve-overlay-file.test.sh — unit test for
# resolve_overlay_file. Pure bash + fixtures, no nix. Run directly:
#   bash dev/scripts/resolve-overlay-file.test.sh
#
# Reproduces the context7 → effect-mcp mis-resolution regression and
# verifies the deterministic resolver + exactly-one-match guard.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=dev/scripts/resolve-overlay-file.sh
source "$here/resolve-overlay-file.sh"

pass=0
fail=0
ok() {
  echo "  ok   - $1"
  pass=$((pass + 1))
}
ko() {
  echo "  FAIL - $1" >&2
  fail=$((fail + 1))
}
# assert_base <expected-basename> <path> <label>
assert_base() {
  if [ "$(basename "$2")" = "$1" ]; then
    ok "$3"
  else
    ko "$3 (got $2)"
  fi
}

# The old, buggy resolution — kept here only to demonstrate the
# regression it caused on the fixture below.
old_resolve() {
  local git_url="$1" root="$2" repo_name
  repo_name=$(echo "$git_url" | sed 's|\.git$||' | grep -oP '[^/]+$')
  grep -rl "$repo_name" "$root" --include='*.nix' | head -1
}

# ── Fixture: the exact shape that triggered the bug ────────────────────
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/mcp-servers"

# effect-mcp overlay: fetchFromGitHub tim-smart/effect-mcp, AND a comment
# that names context7 (this is the substring that fooled the old grep).
cat >"$fixture/mcp-servers/effect-mcp.nix" <<'NIX'
{...}: let
  # Pin pnpm_10 for the deps fetch and build. Mirrors context7-mcp.nix.
  rev = "83a768303839b9e125f6c286369a5d9cc26c666e";
  src = fetchFromGitHub {
    owner = "tim-smart";
    repo = "effect-mcp";
    inherit rev;
    hash = "sha256-effectplaceholderhashvaluegoeshere000000000=";
  };
in {}
NIX

# context7-mcp overlay: fetchFromGitHub upstash/context7.
cat >"$fixture/mcp-servers/context7-mcp.nix" <<'NIX'
{...}: let
  rev = "29edf154d82d503532575a73836135eca225b6f4";
  src = fetchFromGitHub {
    owner = "upstash";
    repo = "context7";
    inherit rev;
    hash = "sha256-context7placeholderhashvaluegoeshere0000000=";
  };
in {}
NIX

# kiro-gateway-style overlay: fetchgit URL form.
cat >"$fixture/kiro-gateway.nix" <<'NIX'
{...}: let
  rev = "0398d74f15549bd771480da8fceb21916ce333e5";
  src = fetchgit {
    url = "https://github.com/jwadow/kiro-gateway.git";
    inherit rev;
    hash = "sha256-kirogatewayplaceholderhashvaluegoeshere0000=";
  };
in {}
NIX

# aggregator that names every overlay (like overlays/default.nix).
cat >"$fixture/default.nix" <<'NIX'
{...}: {
  effect-mcp = import ./mcp-servers/effect-mcp.nix {};
  context7-mcp = import ./mcp-servers/context7-mcp.nix {};
  kiro-gateway = import ./kiro-gateway.nix {};
}
NIX

echo "test: regression — the OLD resolver mis-resolves context7 on this fixture"
old_pick=$(old_resolve "https://github.com/upstash/context7.git" "$fixture" || true)
case "$old_pick" in
*context7-mcp.nix) echo "  note - old resolver happened to pick correctly (race); bug is nondeterministic" ;;
*) echo "  note - old resolver picked WRONG file: $(basename "$old_pick") (this is the bug)" ;;
esac

echo "test: fetchFromGitHub identity resolves to the correct overlay"
got=$(resolve_overlay_file "https://github.com/upstash/context7.git" "$fixture")
assert_base "context7-mcp.nix" "$got" "context7 -> context7-mcp.nix"

got=$(resolve_overlay_file "https://github.com/tim-smart/effect-mcp.git" "$fixture")
assert_base "effect-mcp.nix" "$got" "effect-mcp -> effect-mcp.nix"

echo "test: fetchgit URL identity resolves"
got=$(resolve_overlay_file "https://github.com/jwadow/kiro-gateway.git" "$fixture")
assert_base "kiro-gateway.nix" "$got" "kiro-gateway -> kiro-gateway.nix"

echo "test: missing mapping fails loudly (0 matches -> non-zero)"
if resolve_overlay_file "https://github.com/nobody/does-not-exist.git" "$fixture" >/dev/null 2>&1; then
  ko "missing mapping should have failed"
else
  ok "missing mapping returns non-zero"
fi

echo "test: ambiguous mapping fails loudly (>1 match -> non-zero)"
cp "$fixture/mcp-servers/context7-mcp.nix" "$fixture/mcp-servers/context7-dup.nix"
if resolve_overlay_file "https://github.com/upstash/context7.git" "$fixture" >/dev/null 2>&1; then
  ko "ambiguous mapping should have failed"
else
  ok "ambiguous mapping returns non-zero"
fi
rm -f "$fixture/mcp-servers/context7-dup.nix"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
