#!/usr/bin/env bash
# dev/scripts/update-init.sh — pipeline initialization.
# Runs once before any update targets. Ensures clean state.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

# ── ANSI colors ──────────────────────────────────────────────────────────────
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

echo "${BOLD}${CYAN}══════════════════════════════════════════════════${RESET}"
echo "${BOLD}${CYAN}  Pipeline init${RESET}"
echo "${BOLD}${CYAN}══════════════════════════════════════════════════${RESET}"

# Abort any stuck cherry-pick from a prior crashed run
git cherry-pick --abort 2>/dev/null || true

# Clear report from prior runs
rm -f .update-report.txt

echo "  Ready."
