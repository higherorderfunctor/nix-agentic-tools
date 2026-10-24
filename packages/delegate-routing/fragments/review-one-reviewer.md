For a change outside shared abstractions, use one reviewer from a different
vendor than the worker, following the first check below. Its supported issues
are accepted findings for the loop. For a shared abstraction (`lib/**`,
`packages/*/lib/**`, option declarations or carried patches), use all three
checks in fresh contexts. Use different models for the two checks where
possible. Report disagreements only.

**First check:** gets the draft and requirements. Finds issues and checks each
against the draft itself. For each issue, returns its location, the requirement
it breaks, evidence, whether it holds, and a proposed severity; if uncertain,
returns the open question that would settle it.

**Second check:** gets each issue that holds and its location, without the first
check's reasoning, evidence or severity. Independently checks the draft for what
would make the issue wrong. Returns concede, or rebut with its own evidence.

**Judge:** handles rebutted issues, high-severity concessions and a small sample
of low-severity concessions to check for lazy agreement. Gets both checks'
outcomes and evidence, without their reasoning, proposed severity, round number,
writer's notes or recurrence count. Returns accepted with final severity,
rejected, or unresolved with the open question; names which point it set aside
and why. The orchestrator validates unresolved questions.

Use neutral briefs: never say what an earlier role concluded or that an issue
already survived a check. Pass outcomes and evidence, not arguments. An issue or
rebuttal without evidence does not count. Reviewers never see the round number,
previous verdict or writer's account of fixes. Send the writer only accepted
issues, with location and severity.
