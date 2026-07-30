#!/usr/bin/env bash
#
# Seed one persisted session with the workflow flag ON, under the scratch HOME.
#
# WHY SEEDING AT ALL: the workflow gate is a pure function that ORs a per-request
# client setting against a caller-supplied persisted default and floors at false.
# It has exactly two session-creating call sites, and only the LOAD one passes
# the persisted fallback — the CREATE one calls it with a single argument, so a
# fresh session can never turn workflows on. The shipped client, separately,
# never sends the setting at all and there is no config key that maps to it. So
# writing the flag into a persisted session and re-entering that session is not
# merely one enable path, it is the only one that does not patch a binary.
#
# The flag is resolved once per load and stored, so it cannot be toggled
# mid-session: every run needs its own pre-seeded session.
#
# Usage: seed-session.sh [session-id]
#   Reads KIRO_FIXTURE_HOME and KIRO_FIXTURE_WORKSPACE (see scratch-up.sh).
#   Prints the session id and its directory.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"

: "${KIRO_FIXTURE_HOME:?run scratch-up.sh and eval its output first}"
: "${KIRO_FIXTURE_WORKSPACE:?run scratch-up.sh and eval its output first}"
: "${KIRO_FIXTURE_SCRATCH:?run scratch-up.sh and eval its output first}"

# Mint a v4 UUID. The engine's own validator is far looser than the real format
# — /^[A-Za-z0-9_-]+$/ up to 128 chars, no prefix required — but the shipped Rust
# client parses ids too, so the real `sess_<uuid4>` shape is used to stay
# indistinguishable to it.
mint_uuid() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import uuid; print(uuid.uuid4())'
  elif [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    echo "no way to mint a uuid (need python3 or /proc/sys/kernel/random/uuid)" >&2
    return 1
  fi
}

session_id="${1:-sess_$(mint_uuid)}"

if ! [[ $session_id =~ ^[A-Za-z0-9_-]{1,128}$ ]]; then
  echo "refusing: session id '${session_id}' fails the engine's own charset check" >&2
  exit 1
fi

workspace="$KIRO_FIXTURE_WORKSPACE"
session_dir="$(kiro_session_dir "$KIRO_FIXTURE_HOME" "$session_id" "$workspace")"

kiro_assert_under_scratch "$session_dir" "$KIRO_FIXTURE_SCRATCH"
mkdir -p "$session_dir"

# The bucket and session directories must be REAL, not symlinks — see
# kiro_assert_real's comment for the split symptom that causes.
kiro_assert_real "$session_dir"
kiro_assert_real "$(dirname "$session_dir")"

now="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"

# The seed. Nine keys, and every one of them is load-bearing:
#
#   Seven are schema-REQUIRED (schemaVersion, id, title, agentMode,
#   workspacePaths, createdAt, lastModifiedAt). Omitting any one fails the parse
#   with a corrupted-data error.
#
#   workflowsEnabled goes at the TOP LEVEL. There is no nested "metadata"
#   wrapper on disk: the loader parses the file's top level AS the metadata
#   object and the gate reads the persisted field straight off it. Nesting it
#   would make it an unknown key, which this schema silently STRIPS rather than
#   rejecting — so the flag would read as absent and floor to false, with
#   nothing reporting a problem.
#
#   createdReason is a self-tag. Extra keys cannot be used as markers because
#   both metadata writers re-validate through the same schema and strip them on
#   the first write-back, whereas createdReason is schema-blessed. No session on
#   the capture machine carried it, so its presence in a later sweep is
#   unambiguously harness-authored.
#
# Deliberately OMITTED:
#   - messages.jsonl entirely. A missing file, an empty file and unparseable
#     lines all degrade to zero messages, and transcript-less sessions are a
#     shape the engine itself produces.
#   - status. It is a closed enum, and an invalid value fails the WHOLE parse.
#   - snapshots/ (its .hash is the only integrity check in the tree),
#     publish.cursor, publish-sub.cursor, sub-executions/.
#   - _meta.kiro.workflow. It associates a session with a workflow RUN and swaps
#     its steering to the step-completion protocol — the opposite of what a drain
#     harness wants — and a malformed _meta degrades to absent SILENTLY, unlike a
#     typo in a required field.
cat >"$session_dir/session.json" <<EOF
{
  "agentMode": "vibe",
  "createdAt": "${now}",
  "createdReason": "human",
  "id": "${session_id}",
  "lastModifiedAt": "${now}",
  "schemaVersion": "1.0.0",
  "title": "mode-F workflow fixture",
  "workflowsEnabled": true,
  "workspacePaths": ["${workspace}"]
}
EOF

# Fail loudly here rather than at load: a malformed seed is the one failure mode
# that IS loud, so there is no reason to discover it later.
if ! jq -e . "$session_dir/session.json" >/dev/null; then
  echo "refusing: the seed is not valid JSON" >&2
  exit 1
fi

# The id must equal the directory basename. Load derives the path from the
# REQUESTED id, but every later save derives it from metadata.id — so a mismatch
# loads correctly once and then writes the session's subsequent state into a
# different directory.
if [ "$(jq -r '.id' "$session_dir/session.json")" != "$(basename "$session_dir")" ]; then
  echo "refusing: metadata.id does not equal the session directory name" >&2
  exit 1
fi

# The stored workspacePaths must match the launch cwd, not merely hash into the
# same bucket: a cwd-scoped listing compares the stored array against the
# requested paths and skips a session whose primary path is absent.
if [ "$(jq -r '.workspacePaths[0]' "$session_dir/session.json")" != "$workspace" ]; then
  echo "refusing: workspacePaths[0] does not equal the scratch workspace" >&2
  exit 1
fi

printf 'session_id=%s\n' "$session_id"
printf 'session_dir=%s\n' "$session_dir"
printf 'bucket=%s\n' "$(basename "$(dirname "$session_dir")")"
printf 'launch_cwd=%s\n' "$workspace"
cat <<'EOF'

Next: launch from EXACTLY that cwd, with HOME redirected, resuming BY ID.
The bucket is derived from the request's cwd, so launching elsewhere puts the
lookup in a different bucket and silently creates a fresh session instead.

  (cd "$KIRO_FIXTURE_WORKSPACE" && env HOME="$KIRO_FIXTURE_HOME" \
     kiro-cli --v3 --tui --resume-id <session_id>)

Then run assert-seed-took.sh before trusting anything the session shows you.
EOF
