#!/usr/bin/env bash
#
# Self-test for the seed-and-assert chain, with NO Kiro launch.
#
# The live runs are operator-driven, but the part that most needs testing is not
# the launch — it is the DECISION TREE that interprets the result. A seeded
# session that was never read produces no error, so assert-seed-took.sh is the
# only thing standing between "the enable path does not work" and "I put the file
# in the wrong directory". A decision tree nobody has exercised is not a decision
# tree.
#
# So every branch is driven here against a FABRICATED log. Fabrication is honest
# for this purpose: the assertions are string and filesystem predicates over log
# content, and what is being tested is the predicate, not the engine. The engine
# facts those strings encode are established in the corpus records; the live runs
# confirm the strings appear.
#
# Writes only under its own scratch root. Launches nothing.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

root="${TMPDIR:-/tmp}/kiro-mode-f-self-test.$$"
trap 'rm -rf "$root" "${root%/}.logs-kept" 2>/dev/null || :' EXIT

pass_n=0
fail_n=0

check() {
	local label="$1" want_rc="$2" want_text="$3"
	shift 3
	local out rc=0
	out="$("$@" 2>&1)" || rc=$?
	if [ "$rc" -eq "$want_rc" ] && [[ $out == *"$want_text"* ]]; then
		printf 'ok    %s\n' "$label"
		pass_n=$((pass_n + 1))
		return 0
	fi
	printf 'FAIL  %s (wanted rc=%d%s, got rc=%d)\n' "$label" "$want_rc" "${want_text:+ and $want_text}" "$rc" >&2
	printf '      %s\n' "$out" >&2
	fail_n=$((fail_n + 1))
	return 0
}

# Fabricate an engine log that says the right things. Every string here is a
# substring the real engine emits; assert-seed-took.sh matches on substrings, so
# this exercises the same code path a real log would.
write_log() {
	local home="$1" sid="$2" root_path="$3" extra="${4:-}" loads="${5:-2}"
	local dir="$home/.kiro/logs/20260730T000000"
	mkdir -p "$dir"
	{
		printf '{"level":"info","msg":"Initializing persistence at %s"}\n' "$root_path"
		local i=0
		while [ "$i" -lt "$loads" ]; do
			printf '{"level":"info","msg":"[SessionPersistence] Loaded session %s"}\n' "$sid"
			i=$((i + 1))
		done
		# An `if` rather than `[ -n "$extra" ] && printf ...` on purpose: that form
		# would be the LAST command in this group, so an empty $extra makes the
		# group exit 1 and inherit_errexit kills the caller. Strict mode caught it
		# here; it is worth not reintroducing.
		if [ -n "$extra" ]; then
			printf '%s\n' "$extra"
		fi
	} >"$dir/kiro.log"
}

setup() {
	rm -rf "$root"
	export KIRO_FIXTURE_SCRATCH="$root"
	local out seed_out
	out="$("$here/scratch-up.sh")"
	eval "$out"
	seed_out="$("$here/seed-session.sh")"
	SID="$(printf '%s' "$seed_out" | sed -n 's/^session_id=//p')"
	SESSION_DIR="$(printf '%s' "$seed_out" | sed -n 's/^session_dir=//p')"
}

check_seed() {
	local scenario="$1" want_rc="$2" want_text="$3"
	setup
	local session_root="$KIRO_FIXTURE_HOME/.kiro/sessions" extra='' loads=2
	case "$scenario" in
	empty-bucket)
		rm -- "$SESSION_DIR/session.json"
		rmdir -- "$SESSION_DIR"
		;;
	flag-cleared)
		jq '.workflowsEnabled = false' "$SESSION_DIR/session.json" >"$root/session.json"
		mv "$root/session.json" "$SESSION_DIR/session.json"
		;;
	missing-metadata) rm -- "$SESSION_DIR/session.json" ;;
	no-log | well-formed) ;;
	one-load) loads=1 ;;
	# The on-disk footprint is independent of the log marker.
	rival-session) mkdir -p "$(dirname "$SESSION_DIR")/sess_rival-0000-0000-0000-000000000000" ;;
	# A missing seed silently creates a fresh session with workflows off.
	seed-recreated) extra='{"level":"info","msg":"session.load.create_uncreated"}' ;;
	# The engine wrote logs but resolved a different session root.
	wrong-root) session_root='/some/other/home/.kiro/sessions' ;;
	zero-loads) loads=0 ;;
	*)
		printf 'unknown seed scenario: %s\n' "$scenario" >&2
		exit 2
		;;
	esac
	if [ "$scenario" != no-log ]; then
		write_log "$KIRO_FIXTURE_HOME" "$SID" "$session_root" "$extra" "$loads"
	fi
	check "$scenario" "$want_rc" "$want_text" "$here/assert-seed-took.sh" "$SID"
}

# Scenario, exit status, and the verdict, diagnosis, or warning to observe.
check_seed empty-bucket 1 "contains no session directories at all"
check_seed flag-cleared 1 "the gate resolved false and persisted it"
check_seed missing-metadata 1 "FAIL  no session.json at"
check_seed no-log 1 'FAIL  no engine log under the scratch HOME'
check_seed one-load 0 'warn  expected 2 "Loaded session" lines, saw 1'
check_seed rival-session 1 'holds 2 session directories, expected exactly 1'
check_seed seed-recreated 1 "FAIL  'session.load.create_uncreated' is present in the log"
check_seed well-formed 0 'PASS  the seed was loaded and the workflow gate saw it'
check_seed wrong-root 1 "FAIL  session root is '/some/other/home/.kiro/sessions', expected"
check_seed zero-loads 1 'the engine never loaded this id'

# --- seed-session's id restrictions -------------------------------------
# A valid maximum-length id catches an off-by-one rejection; the two bad ids
# distinguish loosening the alphabet from loosening the length limit.
setup
printf -v max_id 'Aa_-%0124d' 0
while IFS='|' read -r label id rc verdict; do
	check "$label" "$rc" "$verdict" "$here/seed-session.sh" "$id"
done <<EOF
accepts all id character classes at the 128-character limit|$max_id|0|session_id=$max_id
refuses a space in the id|bad id with spaces|1|fails the engine's own charset check
refuses an otherwise valid 129-character id|${max_id}0|1|fails the engine's own charset check
EOF

# --- teardown guards -----------------------------------------------------
# Use the scratch HOME and block rm in the refusal cases so a broken guard
# cannot delete anything. The stub's exit status cannot satisfy the check.
mkdir -p "$root/no-delete"
cat >"$root/no-delete/rm" <<'EOF'
#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
echo 'unexpected attempt to delete an unsafe scratch root' >&2
exit 99
EOF
chmod +x "$root/no-delete/rm"
for unsafe in / "$KIRO_FIXTURE_HOME"; do
	check "teardown refuses $unsafe as the scratch root" 1 "refusing: scratch root '$unsafe' is unsafe" \
		env HOME="$KIRO_FIXTURE_HOME" KIRO_FIXTURE_SCRATCH="$unsafe" PATH="$root/no-delete:$PATH" "$here/scratch-down.sh"
done
check "teardown refuses an ancestor of HOME" 1 "refusing: the real $KIRO_FIXTURE_HOME/.kiro lies under the scratch root" \
	env HOME="$KIRO_FIXTURE_HOME" PATH="$root/no-delete:$PATH" "$here/scratch-down.sh"

# --- teardown happy path -------------------------------------------------
setup
check 'teardown exits successfully' 0 '' "$here/scratch-down.sh"
if [ -d "$root" ]; then
	echo 'FAIL  teardown reported success but the scratch root still exists' >&2
	fail_n=$((fail_n + 1))
else
	printf 'ok    scratch root is gone after teardown\n'
	pass_n=$((pass_n + 1))
fi

# --- report ---------------------------------------------------------------
printf '\npassed: %d\nfailed: %d\n' "$pass_n" "$fail_n"
if [ "$fail_n" -ne 0 ]; then
	exit 1
fi
echo 'PASS'
