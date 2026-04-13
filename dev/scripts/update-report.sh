#!/usr/bin/env bash
# dev/scripts/update-report.sh — format the update report.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

REPORT_FILE=".update-report.txt"

echo ""
echo "${BOLD}${CYAN}══════════════════════════════════════════════════${RESET}"
echo "${BOLD}${CYAN}  Update Report${RESET}"
echo "${BOLD}${CYAN}══════════════════════════════════════════════════${RESET}"

if [ ! -f "$REPORT_FILE" ] || [ ! -s "$REPORT_FILE" ]; then
  echo ""
  echo "  No updates were attempted."
  exit 0
fi

# Count each category
updated=$(grep -c '^UPDATED:' "$REPORT_FILE" 2>/dev/null || true)
unchanged=$(grep -c '^NO UPDATES:' "$REPORT_FILE" 2>/dev/null || true)
held_back=$(grep -c '^HELD BACK:' "$REPORT_FILE" 2>/dev/null || true)

# Updated
if [ "$updated" -gt 0 ]; then
  echo ""
  echo "  ${BOLD}${GREEN}UPDATED ($updated):${RESET}"
  grep '^UPDATED:' "$REPORT_FILE" | sed 's/^UPDATED: //' | sort -u | while read -r line; do
    echo "    ${GREEN}✓ $line${RESET}"
  done
fi

# Held back
if [ "$held_back" -gt 0 ]; then
  echo ""
  echo "  ${BOLD}${RED}HELD BACK ($held_back):${RESET}"
  grep '^HELD BACK:' "$REPORT_FILE" | sed 's/^HELD BACK: //' | sort -u | while read -r line; do
    echo "    ${RED}✗ $line${RESET}"
  done
fi

# Unchanged
if [ "$unchanged" -gt 0 ]; then
  echo ""
  echo "  ${BOLD}${YELLOW}NO UPDATES ($unchanged):${RESET}"
  grep '^NO UPDATES:' "$REPORT_FILE" | sed 's/^NO UPDATES: //' | sed 's/ (already up to date)//' | sort -u | paste -sd', ' | fold -s -w 60 | while read -r line; do
    echo "    $line"
  done
fi

echo ""
