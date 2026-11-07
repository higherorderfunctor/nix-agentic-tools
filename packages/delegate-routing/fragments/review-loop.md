Record HEAD as the review base before the first write. Each round reviews the
accumulated diff from the pinned pre-write base to HEAD (`base..HEAD`), plus
touched dependencies. The worker fixes accepted issues within its task without
asking the user. For a stack, each PR is its own task and its own review diff.
An accepted finding is fixed in the PR that introduced it: amend that branch and
restack the PRs above, then re-pin each restacked PR's review base to its
rewritten parent so its diff stays its own; a finding no single PR introduced
goes in the topmost PR involved. A separate PR that only carries fixes to other
PRs' findings is a loop failure, not a deliverable. Stop early when no accepted
issue is medium severity or higher; otherwise repeat write then review, up to 3
rounds. If the same defect survives 2 rounds, change the brief instead of
repeating it. At the cap, return the result, open defects and decision needed.

A finding that breaks neither the happy path nor a guarantee the task or prior
art lists goes on the report's gap list, not into a fix. Never split a change to
get past the round cap.
