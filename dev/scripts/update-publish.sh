#!/usr/bin/env bash
# Publish one completely prepared update; preserve remote human commits.
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
# Why this lane is SKIPPED, or empty. Two things write it: preserve below (a
# human owns the branch) and an existing PR whose patch did not change (a
# rebase-only refresh or no push at all). The receipt carries it as `skip`; a
# failed build verification then gives a notice instead of a red lane, and a
# preserved hold-back is not counted toward escalation.
: >"$RUNNER_TEMP/skip"

# Read back the identity git-bot-identity configured above; the
# human-commit guard below compares every remote commit's author
# against it. Assert it is non-empty rather than let it degrade:
# an empty value makes EVERY commit look human, which would
# silently stop the pipeline pushing anything at all.
bot_email=$(git config user.email || true)
if [ -z "$bot_email" ]; then
  echo "::error::git user.email is unset — the human-commit guard cannot run"
  exit 1
fi

# Record <branch> as touched so stale cleanup keeps its PR. Idempotent: the
# receipt allows each target's branch exactly once.
touch_branch() {
  grep -qxF "$1" "$RUNNER_TEMP/touched-branches" || echo "$1" >>"$RUNNER_TEMP/touched-branches"
}

# Renovate's "modified branch" rule: leave <branch> exactly as it is and skip
# this lane. A failing update usually needs an outside fix that can take more
# than a day, so a human's in-progress commits must never be rebased,
# force-pushed or reset. The branch stays touched, so cleanup keeps its PR.
# Auto-merge is never changed here: a human's pushed fix merges once green.
# A preserve during arming comes AFTER this run already pushed and edited the
# PR; it stops only the arming, it does not undo the publication.
preserve() {
  local preserve_branch=$1 reason=$2
  echo "::warning title=Update branch preserved::Preserving $preserve_branch: $reason"
  touch_branch "$preserve_branch"
  printf '%s\n' "$reason" >"$RUNNER_TEMP/skip"
}

# Print the commits on origin's copy of <branch> that the bot did not both
# author and commit. Compare author AND committer: a human amend can retain
# the bot author while changing the content and committer. Commits already on
# the base are excluded. A failed merge-base falls back to base_head, which
# only WIDENS the range.
remote_human_commits() {
  local remote_ref="refs/remotes/origin/$1" fork_point
  git rev-parse --verify --quiet "$remote_ref" >/dev/null || return 0
  fork_point=$(git merge-base "$remote_ref" "$base_head" || true)
  git log --format='%H %ae %ce' "${fork_point:-$base_head}..$remote_ref" |
    awk -v bot="$bot_email" '$2 != bot || $3 != bot {print $1}'
}

# Classify origin's LIVE copy of <branch> against the head this run expects:
#   same       origin still points at <expected> (empty: still absent)
#   human      it moved, and a commit the bot did not both author and commit
#              is on it -- a human took the branch over
#   moved      it moved or vanished with no such commit
#   unreadable origin could not be read
# It reads git itself, never GitHub's API, so API lag right after the bot's
# own push, or a transient API error, can never look like a take-over. A
# moved head is fetched into refs/remotes/origin/<branch> to read its commits.
remote_state() {
  local state_branch=$1 expected=$2 live
  if ! live=$(git ls-remote origin "refs/heads/$state_branch" | cut -f1); then
    echo unreadable
  elif [ "$live" = "$expected" ]; then
    echo same
  elif [ -n "$live" ] &&
    git fetch --quiet --no-tags origin "+refs/heads/$state_branch:refs/remotes/origin/$state_branch" &&
    [ -n "$(remote_human_commits "$state_branch")" ]; then
    echo human
  else
    echo moved
  fi
}

# A held-back target has not disproved the usefulness of its existing PR.
case $(jq -er .status "$RUNNER_TEMP/prepared.json") in
"HELD BACK")
  held_branch="update/$UPDATE_TARGET"
  held_human=$(remote_human_commits "$held_branch")
  if [ -n "$held_human" ]; then
    # A human is fixing it on the branch; repeated hold-backs are expected
    # until the branch is deleted or its PR is merged, so this one must not
    # escalate.
    preserve "$held_branch" "preparation held back and $(wc -l <<<"$held_human" | tr -d ' ') non-bot commit(s) are on the remote branch."
  else
    # Not a preserve: the bot still owns this branch, so the hold-back counts
    # toward escalation. Touching it only keeps cleanup off the earlier PR.
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
# Repository/App ownership and author/committer guards below scope arming to
# bot updates. A matching branch name by itself is not an identity check.
# The activity endpoint separately verifies the authenticated pusher.
#
# A human taking the PR over preserves the branch and skips the lane without
# changing auto-merge: a non-bot commit, a PR moved to another base or owner,
# or origin's live branch moving to a non-bot commit. A PR view or push
# activity that disagrees with origin is GitHub lagging behind it: re-read,
# then fail red. Any arming failure fails only this target. Matrix siblings
# still finish, and no successful receipt is emitted for a PR that still needs
# an automation retry.
arm_auto_merge() {
  local arm_pr=$1 arm_branch=$2 expected_head=$3 current_pr human_commits reason push_status retry_status attempt
  local unchanged="auto-merge on $arm_pr left unchanged"
  # Recheck after publication as well as before an unchanged PR is re-armed.
  # Commit identities are immutable at this SHA; GitHub separately records
  # who pushed it.
  human_commits=$(git log --format='%H %ae %ce' "$base_head..$expected_head" |
    awk -v bot="$bot_email" '$2 != bot || $3 != bot {print $1}')
  if [ -n "$human_commits" ]; then
    preserve "$arm_branch" "non-bot commits are in $expected_head; $unchanged."
    return 0
  fi
  # GitHub can acknowledge a new PR, or a push, before its PR view and
  # activity rows catch up. When either disagrees with expected_head, origin's
  # live branch decides: unmoved means GitHub is lagging (re-read), moved onto
  # a non-bot commit means a human took over (preserve), and moved with no
  # such commit is unexplained (fail red).
  for attempt in 1 2 3 4 5; do
    reason=""
    if ! current_pr=$(gh pr view "$arm_pr" --json author,autoMergeRequest,baseRefName,headRefName,headRefOid,headRepository,isCrossRepository); then
      reason="PR view unavailable"
    elif ! jq -e '(.autoMergeRequest == null) or
      (.autoMergeRequest | type == "object" and (.enabledAt | type == "string"))' \
      <<<"$current_pr" >/dev/null; then
      echo "::error::Unrecognized auto-merge metadata on $arm_pr; $unchanged."
      return 1
    elif ! jq -e --arg branch "$arm_branch" --arg repo "$GITHUB_REPOSITORY" --arg base "$BRANCH_NAME" \
      '.isCrossRepository == false and .headRepository.nameWithOwner == $repo
       and .baseRefName == $base and .headRefName == $branch
       and (.author.login == "app/nix-agentic-tools-bot" or .author.login == "nix-agentic-tools-bot[bot]")' \
      <<<"$current_pr" >/dev/null; then
      preserve "$arm_branch" "the repository, base, head branch or author of $arm_pr changed; $unchanged."
      return 0
    elif ! jq -e --arg head "$expected_head" '.headRefOid == $head' <<<"$current_pr" >/dev/null; then
      reason="PR head is not yet $expected_head"
    else
      push_status=0
      python3 "$(dirname "$0")/update-github.py" push "$arm_branch" "$expected_head" || push_status=$?
      case "$push_status" in
      0) break ;;
      3) reason="App push activity unavailable" ;;
      *) reason="App push activity does not verify $expected_head" ;;
      esac
    fi
    if [ "$reason" != "PR view unavailable" ]; then
      case $(remote_state "$arm_branch" "$expected_head") in
      human)
        preserve "$arm_branch" "origin's $arm_branch moved off $expected_head onto non-bot commits; $unchanged."
        return 0
        ;;
      moved)
        echo "::error::origin's $arm_branch moved off $expected_head with no non-bot commit; $unchanged."
        return 1
        ;;
      unreadable) reason="$reason, and origin could not be read" ;;
      *) ;; # same: origin agrees with expected_head, so GitHub is lagging
      esac
    fi
    if [ "$attempt" -eq 5 ]; then
      echo "::error::$reason after $attempt reads for $arm_pr; $unchanged."
      return 1
    fi
    echo "::warning::$reason for $arm_pr (read $attempt/5); retrying before auto-merge."
    sleep 2
  done
  if jq -e '.autoMergeRequest != null' <<<"$current_pr" >/dev/null; then
    echo "Auto-merge already armed for $arm_branch ($arm_pr)"
    return 0
  fi
  # A human can disable auto-merge while the metadata recheck waits. Honor
  # that latest intent before attempting a new enable.
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
  else
    echo "::error title=Auto-merge not armed::Could not arm auto-merge on $arm_pr ($arm_branch) — a later sweep will retry."
    # The mutation was attempted and may have partially succeeded. Roll it
    # back before failing; pre-arm validation failures return above untouched.
    gh pr merge "$arm_pr" --disable-auto || echo "::warning::Could not confirm auto-merge is disabled on $arm_pr."
    return 1
  fi
}

record_published_pr() {
  printf '%s\n' "$1" >"$RUNNER_TEMP/published-pr"
}

# Wait for GitHub to attribute <head> on <branch> to the App. Every non-match
# is re-read, because the activity row trails the push; the caller decides
# what a final non-match means.
app_push_verified() {
  local verify_branch=$1 verify_head=$2 attempt
  for attempt in 1 2 3 4 5; do
    if python3 "$(dirname "$0")/update-github.py" push "$verify_branch" "$verify_head"; then
      return 0
    fi
    if [ "$attempt" -lt 5 ]; then
      echo "::warning::App push activity does not yet verify $verify_head on $verify_branch (read $attempt/5); retrying."
      sleep 2
    fi
  done
  return 1
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

  # A head name alone also matches forks. Only our own repository and App
  # PR may be edited or armed; a human-owned PR on our branch is preserved.
  candidates=$(gh pr list --state open --head "$branch" --limit 1000 \
    --json author,baseRefName,headRepository,isCrossRepository,mergeable,number)
  jq -e 'type == "array" and length < 1000' <<<"$candidates" >/dev/null
  own_prs=$(jq -c --arg repo "$GITHUB_REPOSITORY" \
    '[.[] | select(.isCrossRepository == false and .headRepository.nameWithOwner == $repo)]' \
    <<<"$candidates")
  jq -e 'length <= 1' <<<"$own_prs" >/dev/null
  pr_json=$(jq -c '.[0] // {}' <<<"$own_prs")
  existing_pr=$(jq -r '.number // empty' <<<"$pr_json")
  existing_base=$(jq -r '.baseRefName // empty' <<<"$pr_json")
  pr_mergeable=$(jq -r '.mergeable // "UNKNOWN"' <<<"$pr_json")
  pr_note=${existing_pr:+ (PR #$existing_pr)}
  if [ -n "$existing_pr" ] && [ "$existing_base" != "$BRANCH_NAME" ]; then
    preserve "$branch" "existing PR #$existing_pr targets $existing_base, not $BRANCH_NAME."
    continue
  fi
  if [ -n "$existing_pr" ] && ! jq -e \
    '.author.login == "app/nix-agentic-tools-bot" or .author.login == "nix-agentic-tools-bot[bot]"' \
    <<<"$pr_json" >/dev/null; then
    preserve "$branch" "existing PR #$existing_pr is not owned by the update App."
    continue
  fi

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
  remote_ref="refs/remotes/origin/$branch"
  new_id=$(git diff "$base_head".."$branch" | git patch-id --stable | awk '{print $1}')
  old_id=""
  old_base=""
  if git rev-parse --verify --quiet "$remote_ref" >/dev/null; then
    old_base=$(git merge-base "$remote_ref" "$base_head" || true)
    if [ -n "$old_base" ]; then
      old_id=$(git diff "$old_base".."$remote_ref" |
        git patch-id --stable | awk '{print $1}')
    fi
  fi

  # Never clobber human work. Every run REBUILDS this branch
  # from base in a fresh worktree, so a commit someone pushed
  # to the open PR exists only on the remote — the rebuilt
  # local branch has never seen it, and the force-push below
  # would destroy it silently.
  #
  # A patch-id guard alone cannot catch this: a human commit
  # CHANGES the remote diff, so old_id != new_id and the guard
  # reads it as "the dependency moved, push".
  #
  # The stale-PR step's bot allowlist is also a different
  # property — it decides whether to CLOSE a PR a human has
  # engaged with, not whether to overwrite commits on its
  # branch.
  #
  # PRESERVE the branch when anything but the bot authored or committed a
  # commit on it. That is the only take-over signal: it is read from the
  # commits themselves, so GitHub API lag cannot fake it. Replaying the
  # commits onto a freshly re-derived tree could silently combine a human's
  # hand-fix with a bot hash that superseded it, and the human is the only
  # one who can say which wins. The hold ends when the branch is deleted or
  # its PR is merged; until then every sweep skips this lane.
  human_commits=$(remote_human_commits "$branch")
  if [ -n "$human_commits" ]; then
    printf '%s\n' "$human_commits" | while read -r sha; do
      git log --no-walk --format='  %h %an <%ae>: %s' "$sha"
    done
    preserve "$branch" "$(wc -l <<<"$human_commits" | tr -d ' ') non-bot commit(s) are on the remote branch$pr_note."
    continue
  fi
  # A bot-only head must also be a push GitHub attributes to the App. A
  # mismatch that outlasts the re-reads is unexplained, not a take-over:
  # unless origin has since moved onto non-bot commits, fail red.
  observed_head=""
  if git rev-parse --verify --quiet "$remote_ref" >/dev/null; then
    observed_head=$(git rev-parse "$remote_ref")
    if ! app_push_verified "$branch" "$observed_head"; then
      if [ "$(remote_state "$branch" "$observed_head")" = human ]; then
        preserve "$branch" "origin's $branch moved off $observed_head onto non-bot commits$pr_note."
        continue
      fi
      echo "::error::GitHub does not attribute $branch's head $observed_head to the App$pr_note; not publishing."
      exit 1
    fi
  fi

  # A human close holds only the proposal they saw. Bot stale cleanup can be
  # recreated, and a newer dependency patch is a distinct proposal. Query
  # closed PRs only when no open same-repository PR owns the stable branch.
  if [ -z "$existing_pr" ]; then
    closed_candidates=$(gh pr list --state closed --base "$BRANCH_NAME" --head "$branch" --limit 1000 \
      --json author,closedAt,headRefName,headRefOid,headRepository,isCrossRepository,number)
    jq -e 'type == "array" and length < 1000' <<<"$closed_candidates" >/dev/null
    closed_pr_json=$(jq -c --arg repo "$GITHUB_REPOSITORY" '
      [.[] | select(.isCrossRepository == false
        and .headRepository.nameWithOwner == $repo
        and (.author.login == "app/nix-agentic-tools-bot"
          or .author.login == "nix-agentic-tools-bot[bot]"))]
      | sort_by(.closedAt) | reverse | .[0] // {}
    ' <<<"$closed_candidates")
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
          preserve "$branch" "human-closed PR #$closed_pr cannot be compared with the prepared proposal."
          continue
        fi
        if [ "$closed_id" = "$new_id" ]; then
          preserve "$branch" "human-closed PR #$closed_pr already proposed this update."
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

  # The PR already proposes exactly this patch: a rebase onto a newer base, or
  # no push at all, is not a new proposal. Record that as the lane's skip, so
  # a failed build verification is a notice naming the PR rather than a red
  # lane on every sweep after the base moves. Only a new PR or a changed patch
  # (new_id != old_id) is judged red.
  if [ -n "$existing_pr" ] && [ -n "$new_id" ] && [ "$new_id" = "$old_id" ]; then
    printf '%s\n' "PR #$existing_pr already proposes this patch; only its base changed, if anything." >"$RUNNER_TEMP/skip"
  fi

  if [ -n "$existing_pr" ] && [ -n "$new_id" ] && [ "$new_id" = "$old_id" ] &&
    [ "$pr_mergeable" != "CONFLICTING" ] &&
    [ "$old_base" = "$base_head" ]; then
    echo "Skipping $branch (patch unchanged, already on current base)"
    # MUST still count as touched: the stale-PR step below
    # closes and DELETES any update/* PR missing from this
    # file, so a silent skip would make the pipeline close its
    # own valid PR and recreate it on the next run.
    touch_branch "$branch"
    record_published_pr "${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY/pull/$existing_pr"
    if [ "$human_auto_merge_hold" -eq 0 ]; then
      arm_auto_merge "$existing_pr" "$branch" "$observed_head"
    fi
    continue
  fi

  echo "Pushing $branch ($subject)..."
  # Refuse concurrent remote changes, including a human commit arriving after
  # checkout: the lease is the head every check above observed, and an absent
  # remote branch requires an empty expected SHA. A rejected lease is a
  # take-over only when origin's branch now carries non-bot commits.
  if ! git push --force-with-lease="refs/heads/$branch:$observed_head" origin "$branch"; then
    if [ "$(remote_state "$branch" "$observed_head")" = human ]; then
      preserve "$branch" "origin's $branch moved off ${observed_head:-<absent>} onto non-bot commits during publication$pr_note."
      continue
    fi
    echo "::error::Could not push $branch."
    exit 1
  fi

  if [ -n "$existing_pr" ]; then
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
