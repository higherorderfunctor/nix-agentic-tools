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
# `-e` is MANDATORY: a pattern beginning with `--` would otherwise be parsed
# as an option. Only grep's no-match status means zero. Do not print wc's zero
# if grep errored: callers compare the empty observation as a failed check.
count_matches() {
	local mode="$1" input="$2" pattern="$3" count rc
	count="$({ grep -abo "$mode" -e "$pattern" "$input" || {
		rc=$?
		[ "$rc" -eq 1 ]
	}; } | wc -l)" || return 1
	printf '%s\n' "$count"
}

# occ <file> <fixed-string>
occ() { count_matches -F "$@"; }
# occ_re <file> <ere>
occ_re() { count_matches -E "$@"; }

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
	if [[ $got =~ ^[0-9]+$ ]] && [ "$got" -gt 0 ]; then
		printf '  ctl   %-58s %s\n' "$label" "$got"
		pass=$((pass + 1))
	else
		printf '  REFUSE %-57s control has no matches - check the search and artifact\n' "$label"
		refused=$((refused + 1))
	fi
}

# ---------------------------------------------------------------------------
# C-1, part 1 — the engine's home root is HOME, and only HOME
# ---------------------------------------------------------------------------

echo 'C-1 engine: home root is HOME only'

# The fallback when no home directory was handed over.
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

# The fixed-string surface and sessionsPath controls below read the same bundle.
check 'engine: KIRO_HOME occurrences' 0 "$(occ "$bundle" 'KIRO_HOME')"
check 'engine: XDG_DATA_HOME occurrences' 0 "$(occ "$bundle" 'XDG_DATA_HOME')"

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

# HOME survives: the spawn inherits process.env and blanks only Node channel
# variables.
control 'client: spawn inherits {...process.env}' \
	"$(occ "$client" 'env:{...process.env,NODE_CHANNEL_FD:void 0')"

# KIRO_HOME in the client means the .kiro directory ITSELF. Checked semantically
# rather than by quoting minified identifiers: the window around the resolver
# must mention both parts of the fallback: HOME and .kiro.
kh="$({ grep -aboF -e 'process.env.KIRO_HOME' "$client" || true; } |
	head -1 | cut -d: -f1)"
control 'client: process.env.KIRO_HOME read exists' \
	"$(occ "$client" 'process.env.KIRO_HOME')"
if [ -n "$kh" ]; then
	win="$(head -c $((kh + 260)) "$client" | tail -c 320 | tr -c '[:print:]\n' '.')"
	hits=0
	case "$win" in *'.kiro'*) hits=$((hits + 1)) ;; *) ;; esac
	case "$win" in *'process.env.HOME'*) hits=$((hits + 1)) ;; *) ;; esac
	check 'client: KIRO_HOME resolver fallback names .kiro and HOME' 2 "$hits"
fi

# ---------------------------------------------------------------------------
# C-1, part 3 — XDG_DATA_HOME must stay real
# ---------------------------------------------------------------------------

echo
echo 'C-1 XDG_DATA_HOME: an empty credential DB means an interactive login'

control 'client: credential DB filename' "$(occ "$client" 'data.sqlite3')"
check 'client: device-code browser prompt' 1 \
	"$(occ "$client" 'Confirm the following code in the browser')"

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

# Read the named top-level function through its closing brace. The captured
# bundle indents nested closures; the unindented brace ends the function.
function_body() {
	awk -v name="$1" '
		$0 ~ "^(async )?function " name "\\(" { found = 1 }
		found { print }
		found && /^}/ { exit }
	' "$bundle"
}

join_all="$(function_body joinAll)"
# The load-bearing claim: the `all` trigger is failed OR aborted, not just
# failed. This is what makes "all is the conservative choice" wrong.
check 'joinAll aborts on failed OR aborted' 1 \
	"$(occ_re - 'settled === "failed" \|\| settled === "aborted"' <<<"$join_all")"

join_all_settled="$(function_body joinAllSettled)"
check 'joinAllSettled body awaits allSettled' 1 \
	"$(occ - 'await Promise.allSettled' <<<"$join_all_settled")"
check 'joinAllSettled body mentions abort' 0 \
	"$(occ - 'abort' <<<"$join_all_settled")"

# allSettled still REPORTS failure; it just does not act on it.
check 'joinAllSettled returns the overall result' 1 \
	"$(occ_re - '^ +return overallFromResults\(results\);$' <<<"$join_all_settled")"
check 'overallFromResults reports failed on failed-or-aborted' 1 \
	"$(function_body overallFromResults | occ_re - 'if \(results\.some\(\(r[0-9]*\) => r[0-9]*\.outcome === "failed" \|\| r[0-9]*\.outcome === "aborted"\)\) return "failed";')"

# An outer abort still reaches every branch under EVERY policy. Check the
# handler's loop, not just that a handler with the expected name exists.
scheduler="$(function_body scheduleParallel)"
# A controller-taking declaration is not enough: a swapped switch arm can
# cancel work even when the caller explicitly chose allSettled. Read the
# dispatch for each policy, not an unbound count of calls in the bundle.
while IFS='|' read -r policy call; do
	dispatch="$(awk -v policy="$policy" '
		$0 ~ "^[[:space:]]+case \"" policy "\":$" { in_arm = 1; next }
		in_arm && /^[[:space:]]+(case |break;)/ { exit }
		in_arm { print }
	' <<<"$scheduler")"
	check "scheduler: $policy dispatches with its own controller contract" 1 \
		"$(occ_re - "$call" <<<"$dispatch")"
done <<'EOF'
all|outcome = await joinAll\([A-Za-z0-9_]+, branchControllers, results\);
allSettled|outcome = await joinAllSettled\([A-Za-z0-9_]+, results\);
any|outcome = await joinAny\([A-Za-z0-9_]+, branchControllers, results\);
EOF

outer_abort="$(awk '
	/^  const onOuterAbort = / { found = 1 }
	found { print }
	found && /^  };/ { exit }
' <<<"$scheduler")"
check 'outer abort handler iterates every branch controller' 1 \
	"$(occ_re - 'for \(const c[0-9]* of branchControllers\)' <<<"$outer_abort")"
check 'outer abort handler aborts the current controller' 1 \
	"$(occ_re - 'if \(!c[0-9]*\.signal\.aborted\) c[0-9]*\.abort\(\);' <<<"$outer_abort")"
check 'scheduler registers the outer abort handler' 1 \
	"$(occ - '.addEventListener("abort", onOuterAbort,' <<<"$scheduler")"

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

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------

total=$((pass + fail + refused))
echo
printf 'checks %s  pass %s  fail %s  refused %s\n' "$total" "$pass" "$fail" "$refused"

if [ "$refused" -gt 0 ]; then
	echo 'REFUSE: a positive control had no matches - fix the search before trusting any result'
	exit 2
fi
if [ "$fail" -gt 0 ]; then
	echo 'FAIL'
	exit 1
fi
echo 'PASS'
