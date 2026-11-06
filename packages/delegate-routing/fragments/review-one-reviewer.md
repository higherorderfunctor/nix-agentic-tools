For a change outside shared abstractions, use one reviewer from a different
vendor than the worker, following the first check below. Its supported issues
are accepted findings for the loop. For a shared abstraction (`lib/**`,
`packages/*/lib/**`, option declarations or carried patches), use all three
checks in fresh contexts. Use different models for the two checks where
possible. Report disagreements only.

When the draft exceeds the Size row, the reviewer also names each specific cut
or collapse with evidence: what breaks if it is deleted and the simpler form.
The reviewer never judges its own proposed cuts, and neither does the writer. In
three-check review, the Judge decides which cuts stand; in one-reviewer review,
the orchestrator or another agent does. The writer applies only accepted cuts,
and an accepted cut lands only if checks still pass. The user remains the final
spot-check and is not consulted about cuts.

**First check:** gets the draft, the description's guarantee claims (never its
review history or the writer's notes) and the rubric file verbatim. Grades the
description's claims first, then every rubric row in order: pass with the line
that meets it, fail with location and evidence, or unknown with what would
settle it. A guarantee with no enforcing line in this diff is an issue of at
least medium severity. Then lists issues no row covers, checking each against
the draft itself. For each fail or issue, returns its location, the row or
requirement it breaks, evidence, whether it holds, and a proposed severity; if
uncertain, returns the open question that would settle it.

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
