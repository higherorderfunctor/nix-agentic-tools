#!/usr/bin/env bash
# Publish one completely prepared update; touch a branch only at the bot's own last push.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

# Git and gh must both use this step's fresh App token. The default
# workflow token would require manual approval for downstream PR CI.
gh auth setup-git --hostname github.com

base_head="$UPDATE_BASE_SHA"
: >"$RUNNER_TEMP/touched-branches"
# The PR this run opened, refreshed or kept, for the post-publication verdict
# (update-matrix.py verdict) to name when the target's build verification
# failed. Empty when no PR was published for this target.
: >"$RUNNER_TEMP/published-pr"
# Why this lane is SKIPPED, or empty. Two things write it: skip_lane below
# (origin's branch is not the bot's own last push) and an existing PR whose patch did not
# change (a rebase-only refresh or no push at all). The receipt carries it as
# `skip`; a failed build verification then gives a notice instead of a red
# lane, and a skipped hold-back is not counted toward escalation.
: >"$RUNNER_TEMP/skip"

# Read back the identity git-bot-identity configured above; the
# non-bot-commit check below compares every remote commit's author
# and committer against it. Assert it is non-empty rather than let it
# degrade: an empty value makes EVERY commit look non-bot, which would
# silently stop the pipeline pushing anything at all.
bot_email=$(git config user.email || true)
if [ -z "$bot_email" ]; then
  echo "::error::git user.email is unset — the non-bot-commit check cannot run"
  exit 1
fi

# Every login GitHub reports for the update App, as a jq predicate on a login.
bot_login='. == "app/nix-agentic-tools-bot" or . == "nix-agentic-tools-bot" or . == "nix-agentic-tools-bot[bot]"'

# Record <branch> as touched so stale cleanup keeps its PR. Idempotent: the
# receipt allows each target's branch exactly once.
touch_branch() {
  grep -qxF "$1" "$RUNNER_TEMP/touched-branches" || echo "$1" >>"$RUNNER_TEMP/touched-branches"
}

# Skip this lane with a notice: green, never escalated. The branch stays
# touched, so cleanup keeps its PR.
skip_lane() {
  echo "::notice title=Update lane skipped::Leaving $1 untouched: $2"
  touch_branch "$1"
  printf '%s\n' "$2" >"$RUNNER_TEMP/skip"
}

# The one open PR from this repository on <branch>, as JSON, or {}. A head name
# alone also matches forks, and only our own repository's PR may be edited.
own_open_pr() {
  local candidates
  candidates=$(gh pr list --state open --head "$1" --limit 1000 \
    --json author,baseRefName,headRepository,isCrossRepository,mergeable,number)
  jq -ec --arg repo "$GITHUB_REPOSITORY" '
    if type == "array" and length < 1000 then . else error("PR list may be truncated") end
    | [.[] | select(.isCrossRepository == false and .headRepository.nameWithOwner == $repo)]
    | if length <= 1 then .[0] // {} else error("more than one open PR") end
  ' <<<"$candidates"
}

# Short hashes, one per line, of the commits on <head> since its fork from base
# that the bot did not both author and commit (a human amend can keep the
# bot author while changing the content and committer). Fails on a git error.
non_bot_commits() {
  local fork_point
  fork_point=$(git merge-base "$1" "$base_head" || true)
  git log --format='%h %ae %ce' "${fork_point:-$base_head}..$1" |
    awk -v bot="$bot_email" '$2 != bot || $3 != bot {print $1}'
}

# Renovate's "modified branch" rule, for a human edit only: <head> carries
# commits the bot did not both author and commit. Leave <branch> and its PR
# exactly as they are and skip the lane. A failing update usually needs an
# outside fix that can take more than a day, so a human who moved the branch
# must never have it rebased, force-pushed, retitled or re-armed under them.
# Post ONE comment per <head> on the PR (<pr>, or the open one looked up here)
# saying so; the marker carrying <head> dedupes it across sweeps. A comment
# failure is only a warning: the lane is already skipped and the branch already
# untouched. Every other reason the bot does not own a head (lag, no activity
# row, another bot push) is skip_lane alone: a notice, no comment.
leave_human_edit() {
  local leave_branch=$1 leave_pr=$2 head=$3 reason=$4 marker comments
  skip_lane "$leave_branch" "$reason"
  [ -n "$leave_pr" ] || leave_pr=$(own_open_pr "$leave_branch" | jq -r '.number // empty')
  [ -n "$leave_pr" ] || return 0
  marker="<!-- update-bot-left: $leave_branch $head -->"
  if ! comments=$(gh api --paginate "repos/$GITHUB_REPOSITORY/issues/${leave_pr##*/}/comments"); then
    echo "::warning::Could not read the comments on $leave_pr; not commenting."
    return 0
  fi
  # --paginate prints one array per page; slurp them all.
  if jq -se --arg marker "$marker" "any(.[][]; (.user.login | $bot_login) and (.body | contains(\$marker)))" <<<"$comments" >/dev/null; then
    return 0
  fi
  gh pr comment "$leave_pr" --body "$marker
\`$leave_branch\` changed since this bot last updated it, so the bot left the branch and this PR untouched: $reason

The bot changes this branch only while its head is the bot's own last push. Since someone else committed to it, the bot leaves it alone until the branch is deleted; merging this PR deletes it." ||
    echo "::warning::Could not comment on $leave_pr."
}

# THE ownership gate, the one place the bot decides whether it may touch
# <branch>: push, edit the PR title, or change auto-merge. It may only while
# origin's LIVE head, read with git and never GitHub's API, is exactly
# <expected>, the bot's own last push (empty: the branch must still be
# absent). Otherwise it skips the lane and returns 1, commenting only when the
# new head carries a human's commits (see leave_human_edit). There are no
# re-reads: at four sweeps a day the next one gets it. Origin that git cannot
# read is a genuine error and fails the lane.
bot_owns() {
  local own_branch=$1 expected=$2 own_pr=$3 live reason non_bot
  if ! live=$(git ls-remote origin "refs/heads/$own_branch"); then
    echo "::error::Could not read origin's $own_branch."
    exit 1
  fi
  live=${live%%[[:space:]]*}
  [ "$live" = "$expected" ] && return 0
  reason="origin's head is ${live:-absent}, not the bot's last push ${expected:-(none)}."
  # Comment only on a human edit. A head that cannot be fetched (moved again)
  # or carries only bot commits is skipped quietly; the next sweep re-reads.
  if [ -n "$live" ] && git fetch --quiet --no-tags origin "$live" &&
    non_bot=$(non_bot_commits "$live") && [ -n "$non_bot" ]; then
    leave_human_edit "$own_branch" "$own_pr" "$live" "$reason"
  else
    skip_lane "$own_branch" "$reason"
  fi
  return 1
}

# Is the head this job checked out (refs/remotes/origin/<branch>, or none) the
# bot's own last push, and is origin still there? It must carry only commits
# the bot both authored and committed, and GitHub must credit its push to the
# App, because commit identities are freely chosen. Sets checkout_head.
# Returns 1 after skipping the lane; exits on a git or GitHub API error.
# Every check is explicit, so it holds even when called as a condition.
checkout_head_owned() {
  local own_branch=$1 own_pr=$2 non_bot push_status=0
  checkout_head=$(git rev-parse --verify --quiet "refs/remotes/origin/$own_branch" || true)
  bot_owns "$own_branch" "$checkout_head" "$own_pr" || return 1
  [ -n "$checkout_head" ] || return 0
  if ! non_bot=$(non_bot_commits "$checkout_head"); then
    echo "::error::Could not read the commits on $own_branch."
    exit 1
  fi
  if [ -n "$non_bot" ]; then
    leave_human_edit "$own_branch" "$own_pr" "$checkout_head" "non-bot commits are on $checkout_head: ${non_bot//$'\n'/ }."
    return 1
  fi
  python3 "$(dirname "$0")/update-github.py" push "$own_branch" "$checkout_head" || push_status=$?
  case $push_status in
  0) ;;
  2)
    skip_lane "$own_branch" "GitHub does not credit $checkout_head to the App's push."
    return 1
    ;;
  *)
    echo "::error::Could not read GitHub's push activity for $own_branch."
    exit 1
    ;;
  esac
}

# A held-back target has not disproved the usefulness of its existing PR.
case $(jq -er .status "$RUNNER_TEMP/prepared.json") in
"HELD BACK")
  held_branch="update/$UPDATE_TARGET"
  # Origin's live head decides, not the job-start ref alone. A branch that is
  # not the bot's own last push is skipped, and its hold-backs never escalate.
  if checkout_head_owned "$held_branch" ""; then
    # The bot still owns this branch, so the hold-back counts toward
    # escalation. Touching it only keeps cleanup off the earlier PR.
    touch_branch "$held_branch"
    echo "::warning::Keeping $held_branch and any open PR unchanged: preparation held back."
  fi
  exit 0
  ;;
"NO UPDATES")
  echo "Skipping update/$UPDATE_TARGET (no changes relative to the pinned base)"
  exit 0
  ;;
UPDATED) ;;
*)
  echo "::error::Unrecognized preparation status"
  exit 1
  ;;
esac

# Arm GitHub-native auto-merge on a bot update PR, squash method.
#
# WHY this is safe to do unattended here:
#   - Branch protection on the base requires ZERO approving reviews
#     but DOES require review threads to be resolved. No human
#     sign-off is being bypassed, and an unresolved Copilot thread
#     deliberately leaves the PR armed but unmerged.
#   - The Copilot review comes from a separate ruleset rule that
#     REQUESTS a review. It is not a required approval or status
#     check, but an inline finding gates indirectly through the
#     review-thread rule.
#   - What auto-merge actually waits on is the six required status
#     checks — build (x86_64-linux, ubuntu-latest),
#     build (aarch64-darwin, macos-latest),
#     kiro-patched (x86_64-linux, ubuntu-latest),
#     kiro-patched (aarch64-darwin, macos-latest), test, and
#     gitleaks. A red check leaves the PR sitting armed and unmerged.
#     The full Devenv Diagnostic is NOT among them: after its
#     2026-08-05 demotion, it became workflow_dispatch-only on
#     2026-08-29 when deterministic contracts moved into `test`.
#     Read the ruleset before trusting this list — it is the safety
#     rationale for unattended auto-merge, so a wrong count here is
#     the one that actually matters:
#       gh api repos/OWNER/REPO/rulesets/<id> --jq '.rules[]
#         | select(.type=="required_status_checks")
#         | [.parameters.required_status_checks[].context]'
#   - A merge conflict DISABLES auto-merge on GitHub, so a
#     conflicted update PR drops out of the queue rather than
#     merging something unresolved. The `gh pr edit` path below
#     re-arms it on the next sweep once the force-push has
#     rebuilt the branch on the current base.
#
# Squash is the only method the repository settings permit
# (allow_squash_merge only), so it is passed explicitly.
#
# Arming goes through the ownership gate like every other touch: origin's live
# head must be <expected_head>, the bot's own last push. A PR that GitHub shows
# with another repository, base, head branch, author or head SHA is skipped with
# a notice and no comment: origin already matched, so this is GitHub's PR view
# lagging, and the next sweep re-reads. A failed PR view is an API error, not
# lag. It, malformed metadata and an unclassifiable auto-merge event fail only
# this target. Matrix siblings still finish, and no successful
# receipt is emitted for a PR that still needs an automation retry.
arm_auto_merge() {
  local arm_pr=$1 arm_branch=$2 expected_head=$3 current_pr retry_status after
  bot_owns "$arm_branch" "$expected_head" "$arm_pr" || return 0
  if ! current_pr=$(gh pr view "$arm_pr" --json author,autoMergeRequest,baseRefName,headRefName,headRefOid,headRepository,isCrossRepository); then
    echo "::error::Could not read GitHub's view of $arm_pr ($arm_branch); auto-merge left unchanged."
    return 1
  fi
  if ! jq -e '(.autoMergeRequest == null) or
    (.autoMergeRequest | type == "object" and (.enabledAt | type == "string"))' \
    <<<"$current_pr" >/dev/null; then
    echo "::error::Unrecognized auto-merge metadata on $arm_pr; auto-merge left unchanged."
    return 1
  fi
  if ! jq -e --arg branch "$arm_branch" --arg repo "$GITHUB_REPOSITORY" --arg base "$BRANCH_NAME" --arg head "$expected_head" \
    ".isCrossRepository == false and .headRepository.nameWithOwner == \$repo
     and .baseRefName == \$base and .headRefName == \$branch and .headRefOid == \$head
     and (.author.login | $bot_login)" \
    <<<"$current_pr" >/dev/null; then
    skip_lane "$arm_branch" "GitHub shows $arm_pr with another repository, base, head branch, author or head than $expected_head."
    return 0
  fi
  if jq -e '.autoMergeRequest != null' <<<"$current_pr" >/dev/null; then
    echo "Auto-merge already armed for $arm_branch ($arm_pr)"
    return 0
  fi
  # Honor a human's latest explicit disable before attempting a new enable.
  retry_status=0
  python3 "$(dirname "$0")/update-github.py" auto-merge-retry "${arm_pr##*/}" || retry_status=$?
  case "$retry_status" in
  0) ;;
  2)
    echo "Retaining explicit human auto-merge disable on $arm_pr ($arm_branch)."
    return 0
    ;;
  *)
    echo "::error::Could not classify the latest auto-merge event on $arm_pr ($arm_branch)."
    return 1
    ;;
  esac
  if gh pr merge "$arm_pr" --squash --auto --match-head-commit "$expected_head"; then
    echo "Auto-merge armed (squash) for $arm_branch ($arm_pr)"
    return 0
  fi
  echo "::error title=Auto-merge not armed::Could not arm auto-merge on $arm_pr ($arm_branch) — a later sweep will retry."
  # The enable may have landed before the failure. Undo only this run's own
  # enable: auto-merge was off when it started, so an enable the App owns now
  # is this run's. One a human enabled meanwhile stays.
  if after=$(gh pr view "$arm_pr" --json autoMergeRequest) &&
    jq -e "(.autoMergeRequest.enabledBy.login // \"\") | $bot_login" <<<"$after" >/dev/null; then
    gh pr merge "$arm_pr" --disable-auto || echo "::warning::Could not confirm auto-merge is disabled on $arm_pr."
  fi
  return 1
}

record_published_pr() {
  printf '%s\n' "$1" >"$RUNNER_TEMP/published-pr"
}

# Find all update/* branches with commits ahead of base
git branch --list "update/$UPDATE_TARGET" | while read -r branch; do
  branch=$(echo "$branch" | tr -d ' *+')
  wt_head=$(git rev-parse "$branch")

  if [ "$wt_head" = "$base_head" ]; then
    echo "Skipping $branch (no changes)"
    continue
  fi

  # `git log -1 …`, NOT `git log … | head -1`. This step runs under
  # `set -euETo pipefail`; `head -1` closes the pipe after the first
  # subject, so on any branch with more than one commit ahead of base
  # git dies with SIGPIPE (141), pipefail promotes it, and errexit
  # aborts the ENTIRE branch sweep — every other dependency included.
  # `-1` selects the same newest commit with no pipe at all.
  subject=$(git log -1 --format='%s' "$base_head".."$branch")

  # Only our own repository's App PR may be edited or armed; another base or
  # owner on our branch is someone else's PR, left as it is.
  pr_json=$(own_open_pr "$branch")
  existing_pr=$(jq -r '.number // empty' <<<"$pr_json")
  existing_base=$(jq -r '.baseRefName // empty' <<<"$pr_json")
  pr_mergeable=$(jq -r '.mergeable // "UNKNOWN"' <<<"$pr_json")
  if [ -n "$existing_pr" ] && [ "$existing_base" != "$BRANCH_NAME" ]; then
    skip_lane "$branch" "existing PR #$existing_pr targets $existing_base, not $BRANCH_NAME."
    continue
  fi
  if [ -n "$existing_pr" ] && ! jq -e "(.author.login | $bot_login)" <<<"$pr_json" >/dev/null; then
    skip_lane "$branch" "existing PR #$existing_pr is not owned by the update App."
    continue
  fi

  # Never clobber anyone else's work. Every run REBUILDS this branch from base
  # in a fresh worktree, so a commit someone pushed to the open PR exists only
  # on origin, and the force-push below would destroy it silently. A patch-id
  # guard alone cannot catch this: such a commit CHANGES the remote diff, so
  # it reads as "the dependency moved, push". The ownership gate is the guard.
  checkout_head_owned "$branch" "$existing_pr" || continue

  # Every run rebuilds this branch on the CURRENT base, so its
  # tip SHA always differs even when the dependency did not
  # move — and an unconditional force-push would fire a
  # duplicate 4-job CI run to re-validate a byte-identical
  # patch. `git patch-id --stable` hashes the diff alone, so a
  # pure rebase onto an UNCHANGED base compares equal and the
  # push is skipped.
  #
  # Three conditions keep this honest:
  #   - an empty patch-id means "could not compare", never a
  #     match, or every no-op branch would collapse together;
  #   - a CONFLICTING PR is force-pushed anyway, so branches
  #     cannot rot against a base they no longer apply to
  #     (Renovate's rebaseWhen=conflicted, in effect);
  #   - a branch whose remote base has fallen behind the
  #     current base_head (old_base != base_head) is rebased
  #     and re-pushed even when the dep patch is identical, so
  #     the PR is re-validated against the base it will merge
  #     into (Renovate's rebaseWhen=behind-base-branch). This
  #     is what lets a PR self-heal after a base-branch CI fix
  #     instead of staying pinned to a stale, possibly broken
  #     base.
  new_id=$(git diff "$base_head".."$branch" | git patch-id --stable | awk '{print $1}')
  old_id=""
  old_base=""
  if [ -n "$checkout_head" ]; then
    old_base=$(git merge-base "$checkout_head" "$base_head" || true)
    if [ -n "$old_base" ]; then
      old_id=$(git diff "$old_base".."$checkout_head" |
        git patch-id --stable | awk '{print $1}')
    fi
  fi
  # The PR already proposes exactly this patch: a rebase onto a newer base, or
  # no push at all, is not a new proposal. Record that as the lane's skip, so
  # a failed build verification is a notice naming the PR rather than a red
  # lane on every sweep after the base moves. Only a new PR or a changed patch
  # (new_id != old_id) is judged red.
  same_patch=0
  if [ -n "$existing_pr" ] && [ -n "$new_id" ] && [ "$new_id" = "$old_id" ]; then
    same_patch=1
    printf '%s\n' "PR #$existing_pr already proposes this patch; only its base changed, if anything." >"$RUNNER_TEMP/skip"
  fi

  # A human close holds only the proposal they saw. Bot stale cleanup can be
  # recreated, and a newer dependency patch is a distinct proposal. Query
  # closed PRs only when no open same-repository PR owns the stable branch.
  if [ -z "$existing_pr" ]; then
    closed_candidates=$(gh pr list --state closed --base "$BRANCH_NAME" --head "$branch" --limit 1000 \
      --json author,closedAt,headRefName,headRefOid,headRepository,isCrossRepository,number)
    jq -e 'type == "array" and length < 1000' <<<"$closed_candidates" >/dev/null
    closed_pr_json=$(jq -c --arg repo "$GITHUB_REPOSITORY" "
      [.[] | select(.isCrossRepository == false
        and .headRepository.nameWithOwner == \$repo
        and (.author.login | $bot_login))]
      | sort_by(.closedAt) | reverse | .[0] // {}
    " <<<"$closed_candidates")
    closed_pr=$(jq -r '.number // empty' <<<"$closed_pr_json")
    if [ -n "$closed_pr" ]; then
      close_status=0
      python3 "$(dirname "$0")/update-github.py" close-retry "$closed_pr" || close_status=$?
      case "$close_status" in
      0) ;;
      2)
        closed_head=$(jq -r '.headRefOid // empty' <<<"$closed_pr_json")
        fetched_head=""
        closed_base=""
        closed_id=""
        # A fresh checkout need not contain a deleted closed-PR branch. Fetch
        # GitHub's immutable pull ref without installing a local ref, and
        # require it to match the list API snapshot before comparing patches.
        if [ -n "$closed_head" ] &&
          git fetch --no-tags origin "refs/pull/$closed_pr/head" &&
          fetched_head=$(git rev-parse FETCH_HEAD) &&
          [ "$fetched_head" = "$closed_head" ]; then
          closed_base=$(git merge-base "$fetched_head" "$base_head" || true)
          if [ -n "$closed_base" ]; then
            closed_id=$(git diff "$closed_base".."$fetched_head" |
              git patch-id --stable | awk '{print $1}')
          fi
        fi
        if [ -z "$closed_id" ] || [ -z "$new_id" ]; then
          skip_lane "$branch" "human-closed PR #$closed_pr cannot be compared with the prepared proposal."
          continue
        fi
        if [ "$closed_id" = "$new_id" ]; then
          skip_lane "$branch" "human-closed PR #$closed_pr already proposed this update."
          continue
        fi
        ;;
      *)
        echo "::error::Could not classify who closed PR #$closed_pr ($branch)."
        exit 1
        ;;
      esac
    fi
  fi

  # Read an existing App PR's current auto-merge intent before either reuse
  # path can arm it. Carry an explicit human hold through a safe behind-base
  # refresh: the branch and title still update, but the old PR is not re-armed.
  human_auto_merge_hold=0
  if [ -n "$existing_pr" ]; then
    retry_status=0
    python3 "$(dirname "$0")/update-github.py" auto-merge-retry "$existing_pr" || retry_status=$?
    case "$retry_status" in
    0) ;;
    2)
      human_auto_merge_hold=1
      echo "Retaining explicit human auto-merge disable on PR #$existing_pr ($branch)."
      ;;
    *)
      echo "::error::Could not classify the latest auto-merge event on PR #$existing_pr ($branch)."
      exit 1
      ;;
    esac
  fi

  if [ "$same_patch" -eq 1 ] && [ "$pr_mergeable" != "CONFLICTING" ] &&
    [ "$old_base" = "$base_head" ]; then
    echo "Skipping $branch (patch unchanged, already on current base)"
    # MUST still count as touched: the stale-PR step below
    # closes and DELETES any update/* PR missing from this
    # file, so a silent skip would make the pipeline close its
    # own valid PR and recreate it on the next run.
    touch_branch "$branch"
    record_published_pr "${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY/pull/$existing_pr"
    if [ "$human_auto_merge_hold" -eq 0 ]; then
      arm_auto_merge "$existing_pr" "$branch" "$checkout_head"
    fi
    continue
  fi

  echo "Pushing $branch ($subject)..."
  # Refuse concurrent remote changes: the lease is the head the gate accepted,
  # and an absent remote branch requires an empty expected SHA. A push that
  # fails because origin moved leaves the branch; one that fails while origin
  # has not moved is a genuine error.
  if ! git push --force-with-lease="refs/heads/$branch:$checkout_head" origin "$branch"; then
    bot_owns "$branch" "$checkout_head" "$existing_pr" || continue
    echo "::error::Could not push $branch."
    exit 1
  fi

  if [ -n "$existing_pr" ]; then
    bot_owns "$branch" "$wt_head" "$existing_pr" || continue
    gh pr edit "$existing_pr" --title "$subject"
    echo "PR #$existing_pr updated for $branch"
    record_published_pr "${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY/pull/$existing_pr"
    # Re-arm unless a human explicitly disabled it. Automatic conflict
    # disables and PRs opened before auto-merge existed still self-heal.
    if [ "$human_auto_merge_hold" -eq 0 ]; then
      arm_auto_merge "$existing_pr" "$branch" "$wt_head"
    fi
  else
    cat >"$RUNNER_TEMP/pr-body.md" <<EOF
Automated dependency update.

**Branch:** $branch

Hashes, locks, extracted files, and formatting are prepared before publication.
CI validates the completed branch on x86_64-linux and aarch64-darwin.
Auto-merge (squash) waits for the required checks and review-thread rules.
EOF
    # `gh pr create` prints the new PR's URL on stdout, and that
    # URL is a valid PR reference for `gh pr merge`.
    if pr_url=$(gh pr create \
      --base "$BRANCH_NAME" \
      --head "$branch" \
      --title "$subject" \
      --body-file "$RUNNER_TEMP/pr-body.md"); then
      echo "PR created for $branch: $pr_url"
      record_published_pr "$pr_url"
      arm_auto_merge "$pr_url" "$branch" "$wt_head"
    else
      echo "PR creation failed for $branch"
      exit 1
    fi
  fi

  touch_branch "$branch"
done
