#!/usr/bin/env bash
# Rewrites the egress report's fact fields from the committed facts. Run from
# the repository root. It evaluates the facts through lib.extracted, which
# builds nothing, then runs generate.mjs and formats the report.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

system="$(nix eval --raw --impure --expr builtins.currentSystem)"
facts="$(mktemp)"
trap 'rm -f "$facts"' EXIT
nix eval --json ".#checks.${system}.kimchi-egress-report.passthru.facts" >"$facts"
node dev/skills/kimchi-egress-report/scripts/generate.mjs --facts "$facts"
nix fmt -- packages/kimchi/egress-report.json
