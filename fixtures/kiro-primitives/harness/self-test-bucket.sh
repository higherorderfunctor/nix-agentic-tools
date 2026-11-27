#!/usr/bin/env bash
#
# Self-test for kiro_bucket: reproduce every real v3 session bucket on this
# machine from that session's own recorded workspacePaths.
#
# This is the check that keeps lib.sh's "normalization is identity" assumption
# honest. A bucket the harness cannot reproduce means the harness would seed
# into the wrong directory — and a mis-bucketed seed does NOT error. The engine
# hydrates a fresh session with the workflow flag OFF and writes it over the
# path, so the failure presents as "workflows just didn't turn on", which is
# indistinguishable from a broken enable path. That is why this runs before any
# seeding, and why it refuses on a single mismatch.
#
# READ-ONLY with respect to Kiro state. It reads session.json files and writes
# nothing.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# source-path=SCRIPTDIR resolves the include relative to THIS script rather than
# to the caller's cwd, which is what lets `shellcheck` follow it from the repo
# root the way pre-commit invokes it.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"

sessions_root="${1:-$HOME/.kiro/sessions}"

if [ ! -d "$sessions_root" ]; then
	echo "no sessions root at ${sessions_root} — nothing to verify against" >&2
	exit 1
fi

ok=0
bad=0
skipped=0
v2_skipped=0

shopt -s nullglob
for bucket_dir in "$sessions_root"/*/; do
	bucket="$(basename "${bucket_dir%/}")"

	# The legacy v2 store is a sibling bucket literally named `cli`, with a flat
	# per-conversation layout. It also contains sess_<uuid>.history files, so a
	# `sess_` prefix alone does not mean v3 — exclude it by name.
	if [ "$bucket" = "cli" ]; then
		v2_skipped=$((v2_skipped + 1))
		continue
	fi
	if ! [[ $bucket =~ ^[0-9a-f]{16}$ ]]; then
		echo "SKIP  non-hex bucket: ${bucket}" >&2
		skipped=$((skipped + 1))
		continue
	fi

	# Any one session in the bucket suffices: every session in a bucket shares
	# the workspace path set that produced the bucket name.
	metadata=""
	for candidate in "$bucket_dir"*/session.json; do
		metadata="$candidate"
		break
	done
	if [ -z "$metadata" ]; then
		skipped=$((skipped + 1))
		continue
	fi

	# Read workspacePaths one per line, then PROVE the read was lossless by
	# comparing the element count against jq's own array length.
	#
	# A NUL-separated read is the textbook answer here, but emitting a NUL from
	# jq means either a literal NUL byte in this file — which makes git classify
	# the whole script as binary and costs every reviewable diff on it — or an
	# escape sequence that is easy to mangle in transit. Both have already bitten
	# in this directory. A line-oriented read plus a count check is escape-free,
	# and it turns the single failure mode it has (a path containing a newline)
	# into an explicit refusal rather than a silent mis-join. kiro_bucket still
	# NUL-joins internally, via a printf escape rather than a literal byte.
	mapfile -t paths < <(jq -r '.workspacePaths[]' "$metadata")
	declared="$(jq -r '.workspacePaths | length' "$metadata")"
	if [ "${#paths[@]}" -ne "$declared" ]; then
		printf 'REFUSE %s: read %d path(s) but %d declared - a path contains a newline\n' \
			"$bucket" "${#paths[@]}" "$declared" >&2
		bad=$((bad + 1))
		continue
	fi

	computed="$(kiro_bucket "${paths[@]}")"
	if [ "$computed" = "$bucket" ]; then
		ok=$((ok + 1))
	else
		bad=$((bad + 1))
		printf 'MISMATCH bucket=%s computed=%s paths=%s\n' \
			"$bucket" "$computed" "$(jq -c '.workspacePaths' "$metadata")" >&2
	fi
done

check_bucket() {
	local label="$1" expected="$2" actual
	shift 2
	actual="$(kiro_bucket "$@")"
	if [ "$actual" != "$expected" ]; then
		printf 'MISMATCH %s: bucket=%s, expected %s\n' "$label" "$actual" "$expected" >&2
		bad=$((bad + 1))
	fi
}

# Fixed SHA-256 prefixes for these byte strings (first 16 hex digits).
# Check the empty-set branch separately: it is a literal, not a hash.
check_bucket 'empty path set' '_global'
check_bucket 'one concatenated path' '0731f6eacabd6e75' '/tmp/a/tmp/b'
# Reversed input exercises sorting as well as the NUL separator.
check_bucket 'two paths, supplied in reverse order' 'c4bb7aca9eb3e434' '/tmp/b' '/tmp/a'
# A previous false pass hid whitespace loss; both spellings must be preserved.
check_bucket 'with trailing space' '790f498f3ee65d30' '/tmp/x '
check_bucket 'without trailing space' '2e56aa36f538b33b' '/tmp/x'

printf 'buckets reproduced: %d\n' "$ok"
printf 'mismatched:         %d\n' "$bad"
printf 'no session.json:    %d\n' "$skipped"
printf 'v2 buckets skipped: %d\n' "$v2_skipped"

# A denominator of zero is not a pass. "Every bucket reproduced" is vacuous if
# no bucket was examined, and that is exactly how a broken enumeration would
# present.
if [ "$ok" -eq 0 ]; then
	echo 'FAIL: no buckets were examined - the enumeration found nothing to verify' >&2
	exit 1
fi
if [ "$bad" -ne 0 ]; then
	printf 'FAIL: %d check(s) did not reproduce\n' "$bad" >&2
	exit 1
fi
echo 'PASS'
