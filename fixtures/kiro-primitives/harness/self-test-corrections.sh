#!/usr/bin/env bash
#
# Self-test for the two corrections landed 2026-07-30:
#
#   C-1  (carried-negatives.md) — the two-root model. The engine's home root is
#        HOME only; KIRO_HOME never reaches it; XDG_DATA_HOME must stay real.
#   C-17 (carried-negatives.md, and R-workflow-5 in records/workflow-surface.md)
#        — joinPolicy "all" aborts siblings on failure OR abort; only allSettled
#        structurally cannot, because it is never handed the controllers.
#
# Every assertion below is paired with a POSITIVE CONTROL located by the same
# method in the same file, and the run REFUSES rather than passing when a
# control is zero — otherwise "the claim holds" and "my search stopped parsing
# this file" are the same green.
#
# Anchors are deliberately suffix-agnostic. The bundler rewrites colliding names
# with numeric suffixes (promises6, i5, resolve24) and those churn on every
# release, so the regexes keep the semantic parameter names (controllers,
# results) and wildcard the churn. A rename of `controllers` SHOULD fail this
# test; a renumber of `promises6` should not.
#
# This script never starts a Kiro session. It reads the engine bundle and the
# client binary and nothing else. `kiro_resolve_bundle` shells out to
# `kiro-cli --version`, which is a version query and not a session — but if even
# that is unwanted, pass both paths explicitly and no Kiro executable runs at
# all:
#
#   KIRO_BUNDLE=<path to acp-server.js> KIRO_CLIENT=<path to the chat ELF> \
#     bash <this script>
#
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

# ---------------------------------------------------------------------------
# Resolution
# ---------------------------------------------------------------------------

kasid='(overridden)'
if [ -n "${KIRO_BUNDLE:-}" ]; then
  bundle="$KIRO_BUNDLE"
else
  IFS=$'\t' read -r kasid bundle < <(kiro_resolve_bundle)
fi
[ -f "$bundle" ] || {
  echo "engine bundle not readable: ${bundle}" >&2
  exit 2
}

# The client resolver is R-workflow-3's, verbatim in shape: the Nix-installed
# `bin/kiro-cli-chat` is a small wrapper script rather than the ELF, so the
# `case` arm reaches through to the wrapped binary.
if [ -n "${KIRO_CLIENT:-}" ]; then
  client="$KIRO_CLIENT"
else
  launcher="$(readlink -f "$(command -v kiro-cli)")"
  pkg="$(grep -oE '/nix/store/[a-z0-9]{32}-kiro-cli-[^/]*' "$launcher" | head -1)"
  client="$(readlink -f "$pkg/bin/kiro-cli-chat")"
  case "$(file -bL "$client")" in
  *ELF*) ;;
  *) client="$(dirname "$client")/.$(basename "$client")-wrapped" ;;
  esac
  client="$(readlink -f "$client")"
fi
[ -f "$client" ] || {
  echo "client binary not readable: ${client}" >&2
  exit 2
}

printf 'kasid   %s\n' "$kasid"
printf 'bundle  %s (%s bytes)\n' "$bundle" "$(stat -c%s "$bundle")"
printf 'client  %s (%s bytes)\n\n' "$client" "$(stat -c%s "$client")"

# ---------------------------------------------------------------------------
# Counting
# ---------------------------------------------------------------------------
#
# `grep -c` is unusable here: it counts matching LINES, and on the capture
# machine's `grep` the `-c -o` combination counts occurrences instead, so the two
# forms disagree. `-bo | wc -l` is unambiguous on both.
#
# `-e` is MANDATORY and not stylistic. Without it a pattern beginning with `--`
# is parsed as an option and the count comes back a FALSE ZERO. That trap is
# itself asserted below.

# occ <file> <fixed-string>
occ() { { grep -aboF -e "$2" "$1" || true; } | wc -l; }
# occ_re <file> <ere>
occ_re() { { grep -aboE -e "$2" "$1" || true; } | wc -l; }

pass=0 fail=0 refused=0

# check <label> <expected> <actual>
check() {
  local label="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    printf '  ok    %-58s %s\n' "$label" "$got"
    pass=$((pass + 1))
  else
    printf '  FAIL  %-58s want %s, got %s\n' "$label" "$want" "$got"
    fail=$((fail + 1))
  fi
}

# control <label> <actual> — a positive control must be NON-zero. A zero here is
# not a failed assertion, it is a broken instrument, so it refuses separately.
control() {
  local label="$1" got="$2"
  if [ "$got" -gt 0 ]; then
    printf '  ctl   %-58s %s\n' "$label" "$got"
    pass=$((pass + 1))
  else
    printf '  REFUSE %-57s control is ZERO - search no longer parses file\n' "$label"
    refused=$((refused + 1))
  fi
}

# ---------------------------------------------------------------------------
# C-1, part 1 — the engine's home root is HOME, and only HOME
# ---------------------------------------------------------------------------

echo 'C-1 engine: home root is HOME only'

# The mechanism by which a home dir COULD be overridden, and its fallback.
control 'engine: getCliArg("home-dir") reader exists' \
  "$(occ "$bundle" 'getCliArg("home-dir")')"
control 'engine: os.homedir() fallback exists' \
  "$(occ_re "$bundle" 'os[0-9]*\.homedir\(\)')"

# The handoff is a conditional spread, so an absent argument contributes nothing
# and the fallback is the only remaining path. TWO sites, not one: the engine
# constructs an agent separately for the stdio transport and for the multiplexed
# one, and both spread homeDir the same way — so neither transport can be handed
# a home directory the client did not pass. Asserting 1 here is what caught that.
check 'engine: homeDir handed over as conditional spread' 2 \
  "$(occ_re "$bundle" '\.\.\.homeDir \? \{ homeDir \} : \{\}')"

# Denominator for "the client passes 2 of these": how many arg names exist.
arg_names="$({ grep -aboE -e 'getCliArg\("[a-z-]+"\)' "$bundle" || true; } |
  sed 's/.*getCliArg("//; s/").*//' | LC_ALL=C sort -u)"
check 'engine: distinct CLI arg names accepted' 15 \
  "$(printf '%s\n' "$arg_names" | grep -c .)"
check 'engine: home-dir is among them' 1 \
  "$(printf '%s\n' "$arg_names" | { grep -cxF 'home-dir' || true; })"

# The absence, with its controls immediately above it.
check 'engine: KIRO_HOME occurrences' 0 "$(occ "$bundle" 'KIRO_HOME')"
check 'engine: XDG_DATA_HOME occurrences' 0 "$(occ "$bundle" 'XDG_DATA_HOME')"
control 'engine: control - "homeDir" is present at all' \
  "$(occ "$bundle" 'homeDir')"

# Every engine-side surface composed off the home dir. Four is the whole set:
# sessions, logs, MCP settings, knowledge bases.
check 'engine: homeDir/.kiro composition sites' 4 \
  "$(occ_re "$bundle" 'homeDir, "\.kiro"')"
for surface in sessions logs settings knowledge_bases; do
  control "engine: surface under homeDir/.kiro - ${surface}" \
    "$(occ "$bundle" "\"$surface\"")"
done

# The engine never receives a sessions-root override from its entrypoint: every
# `sessionsPath` mention precedes the arg-parsing block.
last_sessions_off="$({ grep -aboF -e 'sessionsPath' "$bundle" || true; } |
  cut -d: -f1 | LC_ALL=C sort -n | tail -1)"
first_arg_off="$({ grep -aboF -e 'getCliArg(' "$bundle" || true; } |
  cut -d: -f1 | LC_ALL=C sort -n | head -1)"
control 'engine: control - sessionsPath appears at all' \
  "$(occ "$bundle" 'sessionsPath')"
if [ "${last_sessions_off:-0}" -lt "${first_arg_off:-0}" ]; then
  printf '  ok    %-58s %s < %s\n' \
    'engine: no sessionsPath override at entrypoint' "$last_sessions_off" "$first_arg_off"
  pass=$((pass + 1))
else
  printf '  FAIL  %-58s %s >= %s\n' \
    'engine: no sessionsPath override at entrypoint' "$last_sessions_off" "$first_arg_off"
  fail=$((fail + 1))
fi

# ---------------------------------------------------------------------------
# C-1, part 2 — the client never passes --home-dir, and HOME survives the spawn
# ---------------------------------------------------------------------------

echo
echo 'C-1 client: --home-dir is never passed'

check 'client: --home-dir occurrences' 0 "$(occ "$client" '--home-dir')"
control 'client: control - --transport=stdio' "$(occ "$client" '--transport=stdio')"
control 'client: control - --auth=acp-callback' "$(occ "$client" '--auth=acp-callback')"

# THE METHOD IS ITSELF UNDER TEST. Without -e, a `--`-leading pattern is eaten
# as an option and the count is a false zero. If this ever stops differing, the
# absence above has quietly become unfalsifiable.
naive="$({ grep -aboF '--transport=stdio' "$client" 2>/dev/null || true; } | wc -l)"
withe="$(occ "$client" '--transport=stdio')"
if [ "$naive" -eq 0 ] && [ "$withe" -gt 0 ]; then
  printf '  ok    %-58s naive %s vs -e %s\n' \
    'client: -e is load-bearing (false-zero trap live)' "$naive" "$withe"
  pass=$((pass + 1))
else
  printf '  note  %-58s naive %s vs -e %s\n' \
    'client: -e trap did not reproduce on this grep' "$naive" "$withe"
fi

# HOME survives: the spawn inherits process.env and blanks only Node channel
# variables.
control 'client: spawn inherits {...process.env}' \
  "$(occ "$client" 'env:{...process.env,NODE_CHANNEL_FD:void 0')"

# KIRO_HOME in the client means the .kiro directory ITSELF. Checked semantically
# rather than by quoting minified identifiers: the window around the resolver
# must mention both the variable and the directory it falls back to composing.
kh="$({ grep -aboF -e 'process.env.KIRO_HOME' "$client" || true; } |
  head -1 | cut -d: -f1)"
control 'client: process.env.KIRO_HOME read exists' \
  "$(occ "$client" 'process.env.KIRO_HOME')"
if [ -n "$kh" ]; then
  win="$(head -c $((kh + 260)) "$client" | tail -c 320 | tr -c '[:print:]\n' '.')"
  hits=0
  case "$win" in *'KIRO_HOME'*) hits=$((hits + 1)) ;; esac
  case "$win" in *'.kiro'*) hits=$((hits + 1)) ;; esac
  case "$win" in *'process.env.HOME'*) hits=$((hits + 1)) ;; esac
  check 'client: KIRO_HOME resolver names KIRO_HOME, .kiro and HOME' 3 "$hits"
fi

# ---------------------------------------------------------------------------
# C-1, part 3 — XDG_DATA_HOME must stay real
# ---------------------------------------------------------------------------

echo
echo 'C-1 XDG_DATA_HOME: an empty credential DB means an interactive login'

control 'client: credential DB filename' "$(occ "$client" 'data.sqlite3')"
check 'client: device-code browser prompt' 1 \
  "$(occ "$client" 'Confirm the following code in the browser')"
control 'client: browser-open failure path' "$(occ "$client" 'Failed to open browser')"
control 'client: control - "kiro-cli login" remediation string' \
  "$(occ "$client" 'kiro-cli login')"

# On-disk corroboration that the DB really is under XDG_DATA_HOME. Read-only.
datadir="${XDG_DATA_HOME:-$HOME/.local/share}/kiro-cli"
if [ -f "$datadir/data.sqlite3" ]; then
  printf '  ok    %-58s %s\n' 'disk: credential DB under XDG_DATA_HOME' \
    "$datadir/data.sqlite3"
  pass=$((pass + 1))
else
  printf '  note  %-58s absent (never logged in on this machine?)\n' \
    'disk: credential DB under XDG_DATA_HOME'
fi
if [ -d "$datadir/kas" ]; then
  printf '  ok    %-58s %s\n' 'disk: engine bundles under XDG_DATA_HOME too' \
    "$datadir/kas"
  pass=$((pass + 1))
else
  printf '  note  %-58s absent\n' 'disk: engine bundles under XDG_DATA_HOME too'
fi

# ---------------------------------------------------------------------------
# C-17 — join policy: who aborts the losers
# ---------------------------------------------------------------------------

echo
echo 'C-17 join policy: which policies abort their siblings'

# Arity IS the mechanism: a join that is not given the controllers cannot abort.
check 'joinAll declared with controllers' 1 \
  "$(occ_re "$bundle" 'async function joinAll\([A-Za-z0-9_]+, controllers, results\)')"
check 'joinAny declared with controllers' 1 \
  "$(occ_re "$bundle" 'async function joinAny\([A-Za-z0-9_]+, controllers, results\)')"
check 'joinAllSettled declared WITHOUT controllers' 1 \
  "$(occ_re "$bundle" 'async function joinAllSettled\([A-Za-z0-9_]+, results\)')"
check 'joinAllSettled never declared or called with controllers' 0 \
  "$(occ_re "$bundle" 'joinAllSettled\([A-Za-z0-9_]+, controllers')"

# Exactly two sibling-abort sites in the whole bundle: joinAll and joinAny.
check 'sibling-abort call sites in bundle' 2 \
  "$(occ_re "$bundle" 'controllers\[[A-Za-z0-9_]+\]\.abort\(\)')"

# The load-bearing claim: the `all` trigger is failed OR aborted, not just
# failed. This is what makes "all is the conservative choice" wrong.
check 'joinAll aborts on failed OR aborted' 1 \
  "$(occ_re "$bundle" 'settled === "failed" \|\| settled === "aborted"')"

# ... and joinAllSettled's whole body contains no abort at all. The body is
# located by its own signature so the window cannot drift onto a neighbour.
jas="$({ grep -aboE -e 'async function joinAllSettled\(' "$bundle" || true; } |
  head -1 | cut -d: -f1)"
control 'joinAllSettled body located' "${jas:-0}"
if [ -n "$jas" ]; then
  body="$(head -c $((jas + 140)) "$bundle" | tail -c 140)"
  check 'joinAllSettled body mentions abort' 0 \
    "$(printf '%s' "$body" | { grep -coF 'abort' || true; })"
  control 'joinAllSettled body control - awaits allSettled' \
    "$(printf '%s' "$body" | { grep -coF 'Promise.allSettled' || true; })"
fi

# allSettled still REPORTS failure; it just does not act on it.
check 'overallFromResults reports failed on failed-or-aborted' 1 \
  "$(occ_re "$bundle" 'function overallFromResults\(results\) \{')"
control 'overallFromResults call sites' "$(occ "$bundle" 'overallFromResults(results)')"

# An outer abort still reaches every branch under EVERY policy. This is the
# caveat the record states, so it is asserted rather than assumed.
control 'outer abort handler aborts all branch controllers' \
  "$(occ "$bundle" 'const onOuterAbort = ()')"

echo
echo 'C-17 documentation locality: where the sentence lives'

# Each sentence describing sibling fate occurs once, in a bundled agent's
# steering. `joinPolicy` is the denominator: mentions of the field vs.
# explanations of what it does to the losers.
check 'sentence: "First failure aborts siblings"' 1 \
  "$(occ "$bundle" 'First failure aborts siblings')"
check 'sentence: "abort the rest"' 1 "$(occ "$bundle" 'abort the rest')"
check 'sentence: "regardless of individual failures"' 1 \
  "$(occ "$bundle" 'regardless of individual failures')"
control 'denominator: joinPolicy mentions' "$(occ "$bundle" 'joinPolicy')"

# NEGATIVE CONTROL for the counter itself. If a plausible-but-absent spelling
# came back non-zero, every `0` above would be meaningless.
check 'negative control: a plausible absent spelling' 0 \
  "$(occ_re "$bundle" 'async function joinAll\([A-Za-z0-9_]+, results\)')"

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------

total=$((pass + fail + refused))
echo
printf 'checks %s  pass %s  fail %s  refused %s\n' "$total" "$pass" "$fail" "$refused"

# A run whose denominator is zero is not a pass.
if [ "$total" -eq 0 ]; then
  echo 'REFUSE: zero checks executed'
  exit 2
fi
if [ "$refused" -gt 0 ]; then
  echo 'REFUSE: a positive control read zero - fix the search before trusting any result'
  exit 2
fi
if [ "$fail" -gt 0 ]; then
  echo 'FAIL'
  exit 1
fi
echo 'PASS'
