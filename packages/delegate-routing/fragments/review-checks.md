For finder, first-check, second-check and judge, use the rendered helper with
observed techniques. It enforces the Routing helper’s tier, fallback and
exclusion rules. A tier pass does not establish task fit, trial eligibility or
independence; aggregator identity is provisional.

Use the review count this section provides: all three checks when the change is
ready, and one fresh check in the exception below. The first check, the second
check and the judge each put the writer family in their role's `avoid` list. Use
different models for the two checks only when both fit the role at strong or
frontier tier. Otherwise run the best-fitting model again in a fresh context;
never trade fit or tier for variety. Report disagreements only. Hand the whole
review as one job to a delegate on a runtime that runs its own subagents (the
rendered technique notes' "runs own subagents" fact), ideally one whose models
are not the writer's family. If that fact is unknown, probe it in the intended
launcher before relying on it. It runs all three checks itself and returns each
issue's outcome with evidence. When no such runtime is reachable, split the
roles from this session through any tools that pin model and effort, whether a
subagent call, a workflow agent call or an external launcher. An avoided-family
fallback still uses a fresh separate evaluator, never self-evaluation; disclose
its fallback metadata and launch effort. If no qualified route survives shared
fallback, report a loop failure.

One exception, on any forge (GitHub pull requests, GitLab merge requests or
others): a change inside a stack of pull or merge requests, a unit of a branch
still being built, the branch-level review of a branch not yet going ready, and
a fix after any review each get one fresh reviewer whose role avoids the writer
family, following the first check below; that reviewer's supported issues are
accepted findings for the loop. The change gets all three checks when it becomes
ready to merge into the default branch; a fix after that review is reviewed as a
fix, except a nit or low-severity fix the orchestrator judges simple, which
needs no further review. A rebase or restack gets no review, including a
conflict resolved mechanically or by keeping both sides. A conflict that needs a
non-trivial hand merge, and any other rework done during a rebase, gets one
fresh reviewer on that change.

When the draft exceeds the Size row, the reviewer also names each specific cut
or collapse with evidence: what breaks if it is deleted and the simpler form.
The reviewer never judges its own proposed cuts, and neither does the writer.
Whoever judges the cuts — the Judge in three-check review, a separate agent in
stacked one-reviewer review, never the orchestrator — puts both the writer and
the cut proposer's families in its role's `avoid` list. Shared fallback may
select either family as a fresh separate evaluator; it never authorizes an agent
to judge its own work. That judge gets the cuts and their evidence with
authorship stripped (it is not told which agent wrote the code or proposed the
cut) and in neutral order, under the neutral-brief rule. The writer applies only
accepted cuts, and an accepted cut lands only if checks still pass. The user
remains the final spot-check and is not consulted about cuts.

**First check:** gets the draft, the description's guarantee claims (never its
review history or the writer's notes) and the rubric file verbatim. The
orchestrator reads the first unit's diff itself before trusting any report about
it. Apply the Rubric’s Review order row first; then examine its other rows and
the guarantee claims. Every engineering or guarantee question not yet examined
is unknown, not passed. A guarantee with no enforcing line in this diff is an
issue of at least medium severity. For each fail or issue, returns its location,
the row or requirement it breaks, evidence, whether it holds, and a proposed
severity; if uncertain, returns the open question that would settle it.

The reviewer, not the writer, searches for dead code: removed names, dead
branches, checks pinning removed behavior, stale prose and shims. It lists what
it searched, so an empty result differs from not looking.

**Second check:** gets each issue that holds, its location and its rubric row or
requirement, without the first check's reasoning, evidence or severity.
Independently checks the draft for what would make the issue wrong. Returns
concede, or rebut with its own evidence.

**Judge:** rules on every proposed cut, and handles rebutted issues,
high-severity concessions and a small sample of concessions below high severity
to check for lazy agreement. Gets both checks' outcomes and evidence, without
their reasoning, proposed severity, round number, writer's notes or recurrence
count. Returns accepted with final severity, rejected, or unresolved with the
open question; names which point it set aside and why. The orchestrator
validates unresolved questions. A conceded issue the judge does not sample is
accepted at the first check's proposed severity.

Use neutral briefs: never say what an earlier role concluded or that an issue
already survived a check. Pass outcomes and evidence, not arguments. An issue or
rebuttal without evidence does not count. Reviewers never see the round number,
previous verdict or writer's account of fixes. Send the writer only accepted
issues, with location and severity.

A model on trial, with no review track record in this setup, may be an extra
finder but never the second check or the Judge. Preserve these trial limits when
using an avoided-family fallback.
