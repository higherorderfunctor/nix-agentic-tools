#!/usr/bin/env bash
# Delete stale bot-only PRs only after a complete matrix sweep.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

# Refuse to act if the previous step didn't complete.
if [ ! -f "$RUNNER_TEMP/update-completed.flag" ]; then
  echo "Pipeline did not complete cleanly — skipping stale PR cleanup."
  exit 0
fi

gh auth setup-git --hostname github.com
touched="$RUNNER_TEMP/touched-branches"

reopen_pr() {
  local pr=$1 branch=$2 attempt
  for attempt in 1 2 3; do
    if gh pr reopen "$pr"; then
      return 0
    fi
    echo "::warning::Reopen attempt $attempt/3 failed for closed PR #$pr ($branch)."
    [ "$attempt" -eq 3 ] || sleep "$attempt"
  done
  echo "::error::Could not reopen closed PR #$pr ($branch); its branch remains preserved."
  return 1
}

# Allowlist of "non-human" actors. Any review or comment from
# one of these still counts as untouched-by-humans.
#
# Login surface is inconsistent across `gh pr view` fields:
#   .author.login         → "app/nix-agentic-tools-bot"  (App slug)
#   .commits[].authors[]  → "nix-agentic-tools-bot[bot]" (User login)
#   .reviews[].author     → "nix-agentic-tools-bot[bot]" (User login)
#   .comments[].author    → same
# So the allowlist needs BOTH forms for our bot, plus the
# equivalent for GitHub's Copilot reviewer and github-actions.
allowed_logins='[
  "app/nix-agentic-tools-bot",
  "nix-agentic-tools-bot",
  "nix-agentic-tools-bot[bot]",
  "app/copilot-swe-agent",
  "Copilot",
  "copilot",
  "copilot[bot]",
  "copilot-pull-request-reviewer",
  "copilot-pull-request-reviewer[bot]",
  "app/github-actions",
  "github-actions[bot]"
]'

is_bot_only_pr() {
  local pr=$1 branch=$2
  local data
  data=$(gh pr view "$pr" --json author,baseRefName,reviews,comments,headRefName,headRefOid,headRepository,isCrossRepository,state)
  jq -e --arg repo "$GITHUB_REPOSITORY" --arg branch "$branch" --arg base "$BRANCH_NAME" \
    '.isCrossRepository == false and .headRepository.nameWithOwner == $repo and .headRefName == $branch
     and .baseRefName == $base
     and (.reviews | length < 100) and (.comments | length < 100)' <<<"$data" >/dev/null || return 1
  # Refuse potentially truncated activity collections; unknown is preservation.
  pr_head=$(jq -r .headRefOid <<<"$data")
  pr_state=$(jq -r .state <<<"$data")
  [[ $pr_head =~ ^[0-9a-f]{40}$ ]] || return 1

  # Author must be a known bot login (exact match on allowlist)
  jq -e --argjson allow "$allowed_logins" \
    '(.author.login // "") as $a | $allow | any(. == $a)' \
    <<<"$data" >/dev/null || return 1

  # The PR view omits committers. A human amend can retain the bot author,
  # so inspect both mapped identities through the paginated commits endpoint.
  # That endpoint caps a PR at 250 commits; preserve if it could be truncated.
  local commits
  commits=$(gh api --paginate --slurp "repos/$GITHUB_REPOSITORY/pulls/$pr/commits?per_page=100") || return 1
  jq -e --argjson allow "$allowed_logins" \
    'add | (length > 0 and length < 250)
     and all([.author.login // "", .committer.login // ""]
       | all(. as $u | $allow | any(. == $u)))' \
    <<<"$commits" >/dev/null || return 1

  # No reviews by anyone outside the allowlist
  jq -e --argjson allow "$allowed_logins" \
    '[.reviews[]? | .author.login // ""]
     | all(. as $u | $allow | any(. == $u))' \
    <<<"$data" >/dev/null || return 1

  # No comments by anyone outside the allowlist
  jq -e --argjson allow "$allowed_logins" \
    '[.comments[]? | .author.login // ""]
     | all(. as $u | $allow | any(. == $u))' \
    <<<"$data" >/dev/null || return 1

  # Issue comments and submitted reviews omit replies inside review threads.
  python3 "$(dirname "$0")/update-github.py" reviews "$pr" "$allowed_logins" || return 1
  python3 "$(dirname "$0")/update-github.py" push "$branch" "$pr_head" || return 1

  return 0
}

echo "Touched this run:"
if [ -s "$touched" ]; then
  sed 's/^/  /' "$touched"
else
  echo "  (none)"
fi

prs=$(gh pr list --base "$BRANCH_NAME" --state open --limit 1000 \
  --json headRefName,headRepository,isCrossRepository,number)
# If the cap is ever reached, fail rather than silently omit stale candidates.
jq -e 'type == "array" and length < 1000' <<<"$prs" >/dev/null
jq -r --arg repo "$GITHUB_REPOSITORY" \
  '.[] | select(.isCrossRepository == false and .headRepository.nameWithOwner == $repo)
   | select(.headRefName | startswith("update/")) | "\(.number)|\(.headRefName)"' <<<"$prs" |
  {
    reopen_failed=0
    while IFS='|' read -r pr_num pr_branch; do
      if grep -qxF "$pr_branch" "$touched"; then
        echo "PR #$pr_num ($pr_branch): TOUCHED — keep"
        continue
      fi
      if is_bot_only_pr "$pr_num" "$pr_branch"; then
        observed_head=$pr_head
        echo "PR #$pr_num ($pr_branch): BOT-ONLY, untouched — closing"
        if ! gh pr close "$pr_num" \
          --comment "Auto-closed: dependency no longer needs updating (removed from matrix or merged into base). No human activity on the PR."; then
          echo "::warning::Could not close #$pr_num; preserving its branch."
          continue
        fi
        # A force lease cannot detect a new comment or review. Recheck after
        # closing, when a human may have engaged since the initial snapshot.
        if ! is_bot_only_pr "$pr_num" "$pr_branch" || [ "$pr_head" != "$observed_head" ]; then
          echo "::warning::Activity changed or could not be verified after closing; reopening #$pr_num."
          if ! reopen_pr "$pr_num" "$pr_branch"; then
            reopen_failed=1
          fi
          continue
        fi
        if [ "$pr_state" != CLOSED ]; then
          echo "::warning::PR #$pr_num is no longer confirmed closed; preserving its branch."
          continue
        fi
        # `gh pr close --delete-branch` cannot protect a concurrent human push.
        # Use the observed head as an explicit lease and restore the PR if it
        # changed after the activity snapshot. Never delete an unobserved tip.
        if ! git push --force-with-lease="refs/heads/$pr_branch:$observed_head" \
          origin ":refs/heads/$pr_branch"; then
          echo "::warning::Branch changed or deletion failed; reopening #$pr_num."
          if ! reopen_pr "$pr_num" "$pr_branch"; then
            reopen_failed=1
          fi
        fi
      else
        echo "PR #$pr_num ($pr_branch): HUMAN OR UNKNOWN ACTIVITY — preserving"
      fi
    done
    exit "$reopen_failed"
  }
