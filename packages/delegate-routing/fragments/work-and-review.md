Use when a delegate makes a change someone will act on: code, configuration or
prose.

Keep producers and evaluators separate, here and beyond this workflow. A
delegate may produce a plan, diagnosis, finding or change, but is never its only
evaluator. Pair coder with reviewer, planner with executor, researcher with
assessor, and diagnostician with fixer.

The orchestrator briefs review as its own stage before writing starts. A writer
never launches or briefs its own reviewer. Verify a claimed review by its
artifact.

Build a branch as a sequence of units, not one long write. A unit is a bounded
change with one reader and one verification, in whatever shape the language
offers: a module, a class, a library function group, a doc, a test set. One
reader means a single audience takes it in alone; one verification means one
check, test run or reading settles whether it works. Name the units in the brief
before the first write; a writer run covers at most one unit and ends at its
boundary, so the unit's review comes before the next run.

Each unit is reviewed by one fresh separate check whose role avoids the writer
family, using the shared fallback when needed, before the next unit starts.
Reviews attach to units: no review of the whole branch mid-stream. When the
units are done, the branch gets one branch-level review — all three checks when
the PR is going ready, one check in any earlier state. A fix that follows any
review gets a review sized to the fix: the fix's diff plus what it touches, one
check, never the whole branch again.

Two candidate units merge when neither reads alone: if stating what one does
needs the other open, they are one unit. Split a candidate that has two readers
or two verifications; each half then gets the one review that fits it. A Nix
module function group that renders one file is a unit; a doc section that
explains one behavior is a unit; a test set that exercises one added function is
a unit. A unit is not a PR: the Size row still judges the ready branch's total,
and a seam that deserves its own PR is a stack, not a unit.
