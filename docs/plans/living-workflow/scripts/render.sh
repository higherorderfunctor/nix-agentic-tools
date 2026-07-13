#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
S="${1:-state.json}"
echo "# Status board (rendered from ${S} — do not hand-edit)"
echo
echo "## Current position"
jq -r '.current_position
  | "- phase: \(.phase)\n- next: \(.next_action)\n- class: \(.class)\n- branch: \(.branch // "—")"' "$S"
echo
echo "## Phases"
echo "| id | status | title | rationale |"
echo "|----|--------|-------|-----------|"
jq -r '.phases[] | "| \(.id) | \(.status) | \(.title) | \(.ordering_rationale) |"' "$S"
echo
if jq -e '.units and (.units|length>0)' "$S" >/dev/null; then
  echo "## Units"
  echo "| id | phase | status | class | title |"
  echo "|----|-------|--------|-------|-------|"
  jq -r '.units[] | "| \(.id) | \(.phase) | \(.status) | \(.class) | \(.title) |"' "$S"
  echo
fi
echo "## Open items"
jq -r '.open_items[] | "- [\(.disposition)] \(.id): \(.notes // "")"' "$S"
