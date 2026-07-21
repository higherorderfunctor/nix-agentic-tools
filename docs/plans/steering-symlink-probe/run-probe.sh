#!/usr/bin/env bash
# Reproduces the 2026-07-21 finding: kiro-cli v3 silently drops symlinked
# steering LEAF FILES; v2 follows them. See
# docs/plans/factory-steering-materialization-decision.md §1.
#
# Port target: agent-primitive labs, parked as P14 in
# docs/plans/agent-primitive-labs-impl-plan.md.
#
# Usage: ./run-probe.sh [v3|v2]     (default v3)
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

ENGINE="${1:-v3}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# MUST be outside $HOME: Claude ancestor-walks for CLAUDE.md up to /home, and we
# want no ambient config. Kiro is less picky but keep them consistent.
WORK="$(mktemp -d /var/tmp/steering-probe.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/.kiro/steering"

# --- A/B: one real file, one symlink into /nix/store, SAME directory ---
# The swap (run twice, exchanging which token is behind the symlink) is what
# rules out "the model just didn't mention it". Do not skip the swap.
place() {
  local real_token="$1" sym_token="$2"
  rm -f "${WORK:?}/.kiro/steering/"*.md
  cp "$HERE/fixtures/steering/${real_token}-real.md" \
    "$WORK/.kiro/steering/${real_token}-real.md"
  ln -s "$(nix-store --add-fixed sha256 \
    "$HERE/fixtures/steering/${sym_token}-real.md")" \
    "$WORK/.kiro/steering/${sym_token}-symlink.md"
}

ask() {
  local log="$WORK/pty.log"
  local prompt='List every build token documented in your project steering context. Answer from context only, no tools.'
  # A PTY IS LOAD-BEARING. Without `script`, --no-interactive silently runs the
  # v2 Rust loader and you get a FALSE NEGATIVE (this is how the first pass of
  # this investigation reached the wrong conclusion).
  if [ "$ENGINE" = v3 ]; then
    (cd "$WORK" && timeout 120 script -qec \
      "kiro-cli chat --tui --v3 --no-interactive --trust-tools= '$prompt'" \
      "$log" >/dev/null 2>&1) || true
  else
    (cd "$WORK" && timeout 120 kiro-cli chat --no-interactive \
      --trust-tools= "$prompt" >"$log" 2>&1) || true
  fi
  sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' "$log" | tr -d '\r'
}

for pair in "juliet india" "india juliet"; do
  read -r real sym <<<"$pair"
  place "$real" "$sym"
  out="$(ask)"
  # Engine assertion: never trust the flag, assert the banner.
  if [ "$ENGINE" = v3 ] && ! grep -q '\[KiroAgent\]' <<<"$out"; then
    echo "FAIL: v3 requested but [KiroAgent] absent — ran v2, result is invalid" >&2
    exit 1
  fi
  echo "=== engine=$ENGINE  real=$real  symlink=$sym ==="
  grep -oE '(JULIET|INDIA)-[A-Z]+-[0-9]+' <<<"$out" | sort -u | sed 's/^/  loaded: /'
done

cat <<'NOTE'

EXPECTED (kiro-cli 2.13.0):
  v3 → only the REAL token loads in each run; the symlinked one is dropped.
  v2 → BOTH tokens load in each run.
A v3 run that loads both means upstream fixed kirodotdev/Kiro#9787 — re-open the
`strategy` default for Kiro steering in the materialization decision doc.
NOTE
