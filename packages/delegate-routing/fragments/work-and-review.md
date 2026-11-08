Use when a delegate makes a change someone will act on: code, configuration or
prose.

Keep producers and evaluators separate, here and beyond this workflow. A
delegate may produce a plan, diagnosis, finding or change, but is never its only
evaluator. Pair coder with reviewer, planner with executor, researcher with
assessor, and diagnostician with fixer.

Build a branch as a sequence of units, not one long write. A unit is a bounded
change with one reader and one verification, in whatever shape the language
offers: a module, a class, a library function group, a doc, a test set. One
reader means a single audience takes it in alone; one verification means one
check, test run or reading settles whether it works. Name the units in the brief
before the first write; a writer run covers at most one unit and ends at its
boundary, so the unit's review comes before the next run.

Two candidate units merge when neither reads alone: if stating what one does
needs the other open, they are one unit. Split a candidate that has two readers
or two verifications; each half then gets the one review that fits it. A Nix
module function group that renders one file is a unit; a doc section that
explains one behavior is a unit; a test set that exercises one added function is
a unit. A unit is not a PR: the Size row still judges the ready branch's total,
and a seam that deserves its own PR is a stack, not a unit.
