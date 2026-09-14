#!/usr/bin/env bash
# Publish one completely prepared update; preserve remote human commits.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

# Git and gh must both use this step's fresh App token. The default
# workflow token would require manual approval for downstream PR CI.
gh auth setup-git --hostname github.com

base_head="$UPDATE_BASE_SHA"
: >"$RUNNER_TEMP/touched-branches"
# A held-back target has not disproved the usefulness of its existing PR.
case $(jq -er .status "$RUNNER_TEMP/prepared.json") in
"HELD BACK")
  echo "update/$UPDATE_TARGET" >>"$RUNNER_TEMP/touched-branches"
  echo "::warning::Preserving update/$UPDATE_TARGET: preparation held back."
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
# Arming failure fails only this target. Matrix siblings still finish, and no
# successful receipt is emitted for a PR that still needs an automation retry.
arm_auto_merge() {
  local arm_pr=$1 arm_branch=$2 expected_head=$3 current_pr human_commits
  # Recheck after publication as well as before an unchanged PR is re-armed.
  # Commit identities are immutable at this SHA; GitHub separately records
  # who pushed it. A validation failure blocks this arming attempt without
  # treating pusher or commit identity as a request to change merge state.
  if ! current_pr=$(gh pr view "$arm_pr" --json author,autoMergeRequest,baseRefName,headRefName,headRefOid,headRepository,isCrossRepository) ||
    ! jq -e --arg branch "$arm_branch" --arg repo "$GITHUB_REPOSITORY" --arg head "$expected_head" --arg base "$BRANCH_NAME" \
      '.isCrossRepository == false and .headRepository.nameWithOwner == $repo
       and .baseRefName == $base
       and .headRefName == $branch and .headRefOid == $head
       and ((.autoMergeRequest == null) or
         (.autoMergeRequest | type == "object" and (.enabledAt | type == "string")))
       and (.author.login == "app/nix-agentic-tools-bot" or .author.login == "nix-agentic-tools-bot[bot]")' \
      <<<"$current_pr" >/dev/null ||
    ! human_commits=$(git log --format='%H %ae %ce' "$base_head..$expected_head" |
      awk -v bot="$bot_email" '$2 != bot || $3 != bot {print $1}') ||
    [ -n "$human_commits" ] ||
    ! python3 "$(dirname "$0")/update-github.py" push "$arm_branch" "$expected_head"; then
    echo "::error::Cannot verify the current App-owned head of $arm_pr; preserving $arm_branch without changing auto-merge."
    return 1
  fi
  if jq -e '.autoMergeRequest != null' <<<"$current_pr" >/dev/null; then
    echo "Auto-merge already armed for $arm_branch ($arm_pr)"
    return 0
  fi
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

preserve_unverified_head() {
  local preserve_branch=$1 reason=$2
  echo "::warning::Preserving $preserve_branch: $reason"
  echo "$preserve_branch" >>"$RUNNER_TEMP/touched-branches"
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
  if [ -n "$existing_pr" ] && [ "$existing_base" != "$BRANCH_NAME" ]; then
    preserve_unverified_head "$branch" "existing PR #$existing_pr targets $existing_base, not $BRANCH_NAME."
    continue
  fi
  if [ -n "$existing_pr" ] && ! jq -e \
    '.author.login == "app/nix-agentic-tools-bot" or .author.login == "nix-agentic-tools-bot[bot]"' \
    <<<"$pr_json" >/dev/null; then
    echo "::warning::Preserving $branch: existing PR #$existing_pr is not owned by the update App."
    echo "$branch" >>"$RUNNER_TEMP/touched-branches"
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
  # Compare author AND committer against the identity: a human amend can
  # retain the bot author while changing the content and committer. The identity is
  # git-bot-identity configured for this job, and REFUSE the
  # push when anything else authored a commit in range. A
  # refusal is the honest outcome: replaying the commits onto
  # a freshly re-derived tree could silently combine a human's
  # hand-fix with a bot hash that superseded it, and the human
  # is the only one who can say which wins. The branch simply
  # stops auto-updating until they resolve it.
  human_range=""
  if git rev-parse --verify --quiet "$remote_ref" >/dev/null; then
    observed_head=$(git rev-parse "$remote_ref")
    if ! python3 "$(dirname "$0")/update-github.py" push "$branch" "$observed_head"; then
      preserve_unverified_head "$branch" "its observed head is not a verified App push."
      continue
    fi
    # Prefer the merge-base range; fall back to base_head when
    # merge-base could not be computed. The fallback can only
    # WIDEN the range, so it errs toward refusing to push.
    human_range="${old_base:-$base_head}..$remote_ref"
  fi
  if [ -n "$human_range" ]; then
    human_commits=$(git log --format='%H %ae %ce' "$human_range" |
      awk -v bot="$bot_email" '$2 != bot || $3 != bot {print $1}')
    if [ -n "$human_commits" ]; then
      n=$(printf '%s\n' "$human_commits" | wc -l | tr -d ' ')
      echo "::warning title=Update branch has human commits::" \
        "Refusing to force-push $branch — $n non-bot commit(s)" \
        "on the remote branch would be destroyed."
      printf '%s\n' "$human_commits" | while read -r sha; do
        git log --no-walk --format='  %h %an <%ae>: %s' "$sha"
      done
      # As with an unchanged patch, count it as
      # touched so the stale-PR step does not close the PR.
      preserve_unverified_head "$branch" "$n non-bot commit(s) are present on the remote branch."
      continue
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
          preserve_unverified_head "$branch" "human-closed PR #$closed_pr cannot be compared with the prepared proposal."
          continue
        fi
        if [ "$closed_id" = "$new_id" ]; then
          preserve_unverified_head "$branch" "human-closed PR #$closed_pr already proposed this update."
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

  if [ -n "$existing_pr" ] && [ -n "$new_id" ] && [ "$new_id" = "$old_id" ] &&
    [ "$pr_mergeable" != "CONFLICTING" ] &&
    [ "$old_base" = "$base_head" ]; then
    echo "Skipping $branch (patch unchanged, already on current base)"
    # MUST still count as touched: the stale-PR step below
    # closes and DELETES any update/* PR missing from this
    # file, so a silent skip would make the pipeline close its
    # own valid PR and recreate it on the next run.
    echo "$branch" >>"$RUNNER_TEMP/touched-branches"
    if [ "$human_auto_merge_hold" -eq 0 ]; then
      arm_auto_merge "$existing_pr" "$branch" "$observed_head"
    fi
    continue
  fi

  echo "Pushing $branch ($subject)..."
  # Refuse concurrent remote changes, including a human commit arriving
  # after checkout. An absent remote branch requires an empty expected SHA.
  old_tip=$(git rev-parse --verify --quiet "$remote_ref" || true)
  git push --force-with-lease="refs/heads/$branch:$old_tip" origin "$branch"

  if [ -n "$existing_pr" ]; then
    gh pr edit "$existing_pr" --title "$subject"
    echo "PR #$existing_pr updated for $branch"
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
      arm_auto_merge "$pr_url" "$branch" "$wt_head"
    else
      echo "PR creation failed for $branch"
      exit 1
    fi
  fi

  echo "$branch" >>"$RUNNER_TEMP/touched-branches"
done
