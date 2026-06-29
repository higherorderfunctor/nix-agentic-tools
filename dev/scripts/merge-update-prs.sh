#!/usr/bin/env bash
# merge-update-prs.sh — squash-merge passing dependency-update PRs.
#
# Deterministic, AI-optional companion to the Renovate-style update
# pipeline. Targets open PRs authored by the update bot (head branch
# `update/*`) into the working branch, and squash-merges (matching the
# repo's UI merge button) only those whose CI is fully green. Single
# pass — no polling. Because every update PR edits flake.lock, normally
# only the first clean PR merges per run; the rest report BLOCKED
# (conflict) and the Update workflow rebases them — re-run to continue.
#
# Usage:
#   bash dev/scripts/merge-update-prs.sh [--dry-run] [--base <branch>]
# Env:
#   MERGE_DRY_RUN=1            preview only; never merges (same as --dry-run)
#   MERGE_BASE=<branch>        base branch to merge into (default: current branch)
#   MERGE_UNKNOWN_RETRIES=<n>  re-checks when GitHub mergeability is UNKNOWN (default 5)
#   MERGE_UNKNOWN_DELAY=<s>    seconds between those re-checks (default 3)
#
# Requires: gh (authenticated), jq, git.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

bot_logins=("nix-agentic-tools-bot[bot]" "app/nix-agentic-tools-bot")

dry_run="${MERGE_DRY_RUN:-}"
base="${MERGE_BASE:-}"
unknown_retries="${MERGE_UNKNOWN_RETRIES:-5}"
unknown_delay="${MERGE_UNKNOWN_DELAY:-3}"

while [ "$#" -gt 0 ]; do
  case "$1" in
  --dry-run) dry_run=1 ;;
  --base)
    base="${2:?--base needs a branch name}"
    shift
    ;;
  -h | --help)
    sed -n '2,20p' "$0"
    exit 0
    ;;
  *)
    echo "merge-update-prs: unknown argument: $1" >&2
    exit 2
    ;;
  esac
  shift
done

log() { echo "==> $*" >&2; }
die() {
  echo "merge-update-prs: $*" >&2
  exit 1
}

command -v gh >/dev/null || die "gh not found on PATH"
command -v jq >/dev/null || die "jq not found on PATH"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated (run: gh auth login)"

[ -n "$base" ] || base="$(git rev-parse --abbrev-ref HEAD)"
repo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

log "repo=$repo base=$base${dry_run:+ (DRY RUN — no merges)}"

# Candidate PRs: open, into $base, head update/*, authored by the bot.
bot_filter="$(printf '%s\n' "${bot_logins[@]}" | jq -R . | jq -s .)"
prs_json="$(gh pr list --repo "$repo" --base "$base" --state open --limit 200 \
  --json number,headRefName,author)"
mapfile -t candidates < <(
  printf '%s' "$prs_json" | jq -r --argjson bots "$bot_filter" \
    '.[]
       | select(.headRefName | startswith("update/"))
       | select([.author.login] | inside($bots))
       | .number' | sort -n
)

if [ "${#candidates[@]}" -eq 0 ]; then
  log "no open update/* PRs from the bot into $base — nothing to do"
  exit 0
fi
log "found ${#candidates[@]} candidate update PR(s): ${candidates[*]}"

# Classify a PR's aggregate CI as green / pending / failed.
ci_state() {
  jq -r '
    (.statusCheckRollup // []) as $c
    | if ($c | length) == 0 then "pending"
      elif ($c | all(
        if .__typename == "CheckRun"
        then (.status == "COMPLETED"
              and (.conclusion | IN("SUCCESS", "NEUTRAL", "SKIPPED")))
        elif .__typename == "StatusContext" then (.state == "SUCCESS")
        else false end)) then "green"
      elif ($c | any(
        if .__typename == "CheckRun" then (.status != "COMPLETED")
        elif .__typename == "StatusContext"
        then (.state == "PENDING" or .state == "EXPECTED")
        else false end)) then "pending"
      else "failed" end'
}

# Poll a PR's mergeability — GitHub recomputes it asynchronously after
# each merge moves the base, returning UNKNOWN in the meantime. Bounded:
# gives up after a few tries and returns the last value so the caller can
# skip safely. Update PRs touch disjoint flake.lock nodes, so most
# UNKNOWNs resolve to MERGEABLE within seconds.
poll_mergeable() {
  local num=$1 m="UNKNOWN" i=0
  while [ "$i" -lt "$unknown_retries" ]; do
    sleep "$unknown_delay"
    m="$(gh pr view "$num" --repo "$repo" --json mergeable -q .mergeable)"
    if [ "$m" != "UNKNOWN" ]; then break; fi
    i=$((i + 1))
  done
  printf '%s' "$m"
}

merged=()
skipped=()
blocked=()

for num in "${candidates[@]}"; do
  pr="$(gh pr view "$num" --repo "$repo" \
    --json number,title,headRefName,mergeable,statusCheckRollup)"
  title="$(printf '%s' "$pr" | jq -r .title)"
  mergeable="$(printf '%s' "$pr" | jq -r .mergeable)"
  ci="$(printf '%s' "$pr" | ci_state)"
  label="#$num $title"

  if [ "$ci" != "green" ]; then
    log "SKIP  $label — CI $ci"
    skipped+=("$label [$ci]")
    continue
  fi
  if [ "$mergeable" = "UNKNOWN" ]; then
    log "POLL  $label — mergeability not computed yet (up to $((unknown_retries * unknown_delay))s)"
    mergeable="$(poll_mergeable "$num")"
  fi
  if [ "$mergeable" = "CONFLICTING" ]; then
    log "BLOCK $label — conflict (awaiting rebase by Update workflow)"
    blocked+=("$label [conflict]")
    continue
  fi
  if [ "$mergeable" != "MERGEABLE" ]; then
    log "SKIP  $label — mergeable=$mergeable (GitHub recomputing)"
    skipped+=("$label [mergeable=$mergeable]")
    continue
  fi
  if [ -n "$dry_run" ]; then
    log "WOULD MERGE $label (squash + delete)"
    merged+=("$label [dry-run]")
    continue
  fi

  log "MERGE $label (squash + delete)"
  if gh api --method PUT "repos/$repo/pulls/$num/merge" \
    -f merge_method=squash >/dev/null; then
    merged+=("$label")
  else
    log "FAILED to merge $label — left open"
    blocked+=("$label [merge-failed]")
  fi
done

{
  echo
  echo "===== merge-update-prs summary (base: $base) ====="
  echo "merged:  ${#merged[@]}"
  for x in ${merged[@]+"${merged[@]}"}; do echo "  ✓ $x"; done
  echo "skipped: ${#skipped[@]}"
  for x in ${skipped[@]+"${skipped[@]}"}; do echo "  - $x"; done
  echo "blocked: ${#blocked[@]}"
  for x in ${blocked[@]+"${blocked[@]}"}; do echo "  ! $x"; done

  if [ "${#blocked[@]}" -gt 0 ] && [ -z "$dry_run" ]; then
    echo
    echo "Some PRs are blocked (usually flake.lock conflicts). The Update"
    echo "workflow will rebase them after this merge; re-run to continue."
  fi
} >&2
