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

# The empty-set case is a separate code path (a literal, not a hash).
global="$(kiro_bucket)"
if [ "$global" != "_global" ]; then
  printf 'MISMATCH empty path set produced %s, expected _global\n' "$global" >&2
  bad=$((bad + 1))
fi

# Positive control for the separation logic. A path carrying a trailing space
# must NOT hash the same as the trimmed path. If the reader ever regresses to
# splitting on whitespace, these two collapse — and the bucket loop above would
# keep reporting PASS while the harness silently mis-bucketed every seed. This
# control is here because that exact false pass happened once already.
spacey="$(kiro_bucket '/tmp/x ')"
clean="$(kiro_bucket '/tmp/x')"
if [ "$spacey" = "$clean" ]; then
  echo 'MISMATCH trailing-space control collapsed - the reader is splitting on whitespace' >&2
  bad=$((bad + 1))
fi

# Positive control for the joiner: two paths must not hash to the same value as
# their concatenation, which is what a missing separator would produce.
two="$(kiro_bucket '/tmp/a' '/tmp/b')"
concat="$(kiro_bucket '/tmp/a/tmp/b')"
if [ "$two" = "$concat" ]; then
  echo 'MISMATCH join control collapsed - the separator is not being emitted' >&2
  bad=$((bad + 1))
fi

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
