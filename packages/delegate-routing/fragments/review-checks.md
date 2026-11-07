Review every change with all three checks below, each in a fresh context. The
first check, the second check and the judge each run on a vendor other than the
writer's. Use different models for the two checks where possible. Report
disagreements only. Hand the whole review as one job to a delegate on another
vendor's runtime that runs its own subagents (the technique table's "Runs own
subagents" column), such as `codex exec` for work Claude wrote. It runs all
three checks itself, mixing models, and returns each issue's outcome with
evidence. When no such runtime is reachable, split the roles from this session
through tools that pin model and effort: the Workflow tool's agent call, or an
external launcher (`claude -p`, `codex exec`). Skipping the vendor requirement
because one tool's enum lacks the model is a loop failure; report it as one.

One exception, on any forge (GitHub pull requests, GitLab merge requests or
others): a change inside a stack of pull or merge requests gets one reviewer
from a different vendor than the writer while it is stacked, following the first
check below; that reviewer's supported issues are accepted findings for the
loop. The change gets all three checks when it becomes ready to merge into the
default branch. A pure rebase or restack of the stack gets no review; rework
done during a rebase is a change, and the rules above apply to it.

When the draft exceeds the Size row, the reviewer also names each specific cut
or collapse with evidence: what breaks if it is deleted and the simpler form.
The reviewer never judges its own proposed cuts, and neither does the writer.
Whoever judges the cuts — the Judge in three-check review, a separate agent in
stacked one-reviewer review, never the orchestrator — comes from a different
model family than the writer and the cut's proposer. That judge gets the cuts
and their evidence with authorship stripped (it is not told which agent wrote
the code or proposed the cut) and in neutral order, under the neutral-brief
rule. The writer applies only accepted cuts, and an accepted cut lands only if
checks still pass. The user remains the final spot-check and is not consulted
about cuts.

**First check:** gets the draft, the description's guarantee claims (never its
review history or the writer's notes) and the rubric file verbatim. Grades the
description's claims first, then every rubric row in order: pass with the line
that meets it, fail with location and evidence, or unknown with what would
settle it. A guarantee with no enforcing line in this diff is an issue of at
least medium severity. Then lists issues no row covers, checking each against
the draft itself. For each fail or issue, returns its location, the row or
requirement it breaks, evidence, whether it holds, and a proposed severity; if
uncertain, returns the open question that would settle it.

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
finder but never the second check or the Judge. Blend vendors across review
roles.
