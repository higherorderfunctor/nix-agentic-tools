Pin the review base before each loop's first write: for a unit, HEAD before the
unit starts; for a fix round, HEAD before the fix starts; for the branch-level
review, HEAD before the branch's first write. A unit's first round reviews that
unit's accumulated diff from its pinned base to HEAD (`base..HEAD`), plus
touched dependencies; the branch-level review's first round reviews the whole
branch the same way; a fix round reviews only the fix's diff plus what it
touches, and says whether deleting what caused the finding would be smaller than
the fix; if so, that is an open question for the orchestrator, not the next fix.
The worker fixes accepted issues within its task without asking the user.

For a stack, each PR is its own task and its own review diff. An accepted
finding is fixed in the PR that introduced it: amend that branch and restack the
PRs above, then re-pin each restacked PR's review base to its rewritten parent
so its diff stays its own; a finding no single PR introduced goes in the topmost
PR involved. A separate PR that only carries fixes to other PRs' findings is a
loop failure, not a deliverable.

Stop early when no accepted issue is medium severity or higher; otherwise repeat
write then review, up to 3 rounds per loop: a unit's loop and the branch-level
review count their own rounds, and a fix round counts toward the loop it
repairs. Findings that name the same wrong outcome against the same rubric row
or guarantee count as one defect; if it survives 2 rounds, change the brief
instead of repeating the loop, or bring the user a proposal to drop the
requirement that produces it. At the cap, return the result, open defects and
decision needed.

Fix real in-scope nits and follow the Review step's fix-review rule, including
its exception after the ready review. The gap list is for out-of-scope findings
only. The orchestrator applies the final nits directly. A fix round adds only
the test cases its accepted findings need. Report the net line change in each
fix round. Never split a change to get past the round cap.

After two follow-up jobs on one PR (fixes, rework or relaunches), stop and
compare the diff with the approved scope and estimate. Report the comparison to
the user before launching another job.
