For finder, first-check, second-check and judge, use the rendered
`delegate-routing-plan` command with the producer model lines and actual launch
efforts in each checking role's `producers` list. It enforces the
strong/frontier and producer tier floors before ladder ranking; never step down
a tier. A tier pass does not establish task fit, trial eligibility or
cross-maker independence. Makers are declared model-line data; provider, runtime
and budget are separate identities. Honor trial and independence restrictions
before launch. Report no qualified route only when every route is hard-filtered
and the caller cannot run itself.

Review every change with all three checks below, each in a fresh context. The
first check, second check and judge each name the writer as a producer. The
ladder prefers a maker different from all producers, then a different line from
the same maker, then the same line with one extra supported effort step. Use
different models for the two checks where possible. Report disagreements only.

Split review staffing across runtimes by the helper's pool-ranked choices. Each
external runtime gets one orchestrator delegate that runs its assigned roles
through native subagents; roles on the session's own runtime are launched
natively by the session. Before relying on an external runtime's native
subagents, check the rendered technique notes' "runs own subagents" fact; if
unknown, probe the intended launcher. External and non-interactive delegates
never launch another external delegate. A retained producer-line last resort
still needs a fresh separate evaluator for review; `continue-self` does not
satisfy this workflow's independence rule.

One exception, on any forge (GitHub pull requests, GitLab merge requests or
others): a change inside a stack of pull or merge requests, a unit of a branch
still being built, the branch-level review of a branch not yet going ready, and
a fix after any review each get one fresh reviewer whose role names the writer
as a producer, following the first check below; that reviewer's supported issues
are accepted findings for the loop. The change gets all three checks when it
becomes ready to merge into the default branch; a fix after that review is
reviewed as a fix. A pure rebase or restack of the stack gets no review; rework
done during a rebase is a change, and the rules above apply to it.

When the draft exceeds the Size row, the reviewer also names each specific cut
or collapse with evidence: what breaks if it is deleted and the simpler form.
The reviewer never judges its own proposed cuts, and neither does the writer.
Whoever judges the cuts — the Judge in three-check review, a separate agent in
stacked one-reviewer review, never the orchestrator — names both the writer and
the cut proposer in its role's `producers` list, with their actual launch
efforts. The last resort may select either model line as a fresh separate
evaluator; it never authorizes an agent to judge its own work. That judge gets
the cuts and their evidence with authorship stripped (it is not told which agent
wrote the code or proposed the cut) and in neutral order, under the
neutral-brief rule. The writer applies only accepted cuts, and an accepted cut
lands only if checks still pass. The user remains the final spot-check and is
not consulted about cuts.

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
finder but never the second check or the Judge. Preserve these trial limits when
using a producer-line last resort.
