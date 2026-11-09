The orchestrator briefs review as its own stage before writing starts. A writer
never launches or briefs its own reviewer. Verify a claimed review by its
artifact.

Each unit is reviewed by one check, from a maker other than the writer's, before
the next unit starts. Reviews attach to units: no review of the whole branch
mid-stream. When the units are done, the branch gets one branch-level review —
all three checks when the PR is going ready, one check in any earlier state. A
fix that follows any review gets a review sized to the fix: the fix's diff plus
what it touches, one check, never the whole branch again.

The worker does the task to the rubric. For a failing check, test or bug, a
read-only delegate records the root cause with evidence; the orchestrator
validates it, and a different delegate fixes against that diagnosis. Reviewers
check the written diagnosis against the change.

One exception, on any forge (GitHub pull requests, GitLab merge requests or
others): a change inside a stack of pull or merge requests, a unit of a branch
still being built, the branch-level review of a branch not yet going ready, and
a fix after any review each get one reviewer from a different maker than the
writer, following the first-check policy in the prepared reviewer brief; that
reviewer's supported issues are accepted findings for the loop. The change gets
all three checks when it becomes ready to merge into the default branch; a fix
after that review is reviewed as a fix. A pure rebase or restack of the stack
gets no review; rework done during a rebase is a change, and the rules above
apply to it.

When the draft exceeds the Size row, the reviewer also names each specific cut
or collapse with evidence: what breaks if it is deleted and the simpler form.
The reviewer never judges its own proposed cuts, and neither does the writer.
Whoever judges the cuts — the Judge in three-check review, a separate agent in
stacked one-reviewer review, never the orchestrator — comes from a different
maker than the writer and the cut's proposer. That judge gets the cuts and their
evidence with authorship stripped (it is not told which agent wrote the code or
proposed the cut) and in neutral order, under the neutral-brief rule. The writer
applies only accepted cuts, and an accepted cut lands only if checks still pass.
The user remains the final spot-check and is not consulted about cuts.

The orchestrator validates unresolved questions returned by the judge.

The planner prepares base briefs for every reviewer launch before returning the
plan, including second-check and judge, so check-plan can validate their
existence and full rubric. After the first check returns, the orchestrator adds
the earlier checks' inputs to those base briefs before each reviewer launches,
using the role-specific rules below. Preserve the rubric and base policy.
Enrichment changes the actual brief bytes: prepare and accept a new classifier
exchange for that review role before launch; other unchanged roles reuse their
receipts.

Choose each reviewer after its writer finishes. Run `--dispatch` for the planned
review role with current observed techniques and the unit's actual `executions`,
even after successful check-plan. Record the worker and cut proposer from the
launches actually bound to tools, outside role intent; a conflicting context
`writer` is an error. Missing or unknown participant identities cannot authorize
review. A pool change can make a formerly feasible review impossible; report
that failure without substituting a new writer. Dispatch does not prove tool
execution or enforce the review/fix/commit barriers above.

Use neutral briefs: never say that an issue already survived a check. Pass only
the outcomes and evidence permitted for that role, never earlier reasoning or
arguments, proposed severity, round number, previous verdict, recurrence count
or the writer's notes or account of fixes. An issue or rebuttal without evidence
does not count. Send the writer only accepted issues, with location and
severity.

**Second-check inputs:** include each issue that holds, its location and its
rubric row or requirement, without the first check's reasoning, evidence or
severity.

**Judge inputs:** include both checks' outcomes and evidence for every proposed
cut, rebutted issues, high-severity concessions and a small sample of
concessions below high severity to check for lazy agreement.

Open every writer and fixer brief with a hard-rules block before the task. It
gives the literal worktree path every command starts in. It forbids commit,
push, rebase, branch change and git configuration, because the orchestrator
commits. It names the project's coding standards, the checks the writer may and
may not run, the files it may read, and the report's evidence format. When
commit hooks reject patterns writers are known to produce, the brief names each
pattern and its required form, and has the writer run that linter on every
edited file.

Split a brief that needs one section per surface into one writer run per
surface, and a surface with several units into one run per unit. Run them in
sequence when they share a worktree, and commit each before the next.
