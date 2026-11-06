Before the first write, save the rubric to a file: numbered criteria, each a
pass/fail test that a line in the diff settles. Derive each row from the task's
goal (what must be true when done; work outside it fails) and from the project's
rules, naming the rule.

Every rubric carries these standing rows:

1. **Scope.** A plan item names the current artifact field or behavior it
   replaces; one that replaces nothing is cut, or is an optional follow-up with
   its own reason. A mechanism is proportional to what it judges: one that fires
   on changes outside its input (a fingerprint wider than the judged spans,
   failing on every unrelated bump) is a finding, not strictness. The planner
   plans to this row; the plan's first reviewer judges scope against the stated
   goal before any row.
2. **Fixtures.** Fixtures send what a production client sends: a Host or
   authority without a port on a default-port destination, a plain push and not
   only a forced one. A fixture that cannot reproduce production (a port it
   cannot bind) names the difference and what it hides; a path no fixture
   exercises is a finding.
3. **Naming.** A comment or doc names behaviors, files and options, never a plan
   phase, review round or finding id whose document is not in the repository;
   write the decision the label stands for. Numbering the artifact itself
   defines (a script's own phase headings) is a name and stays.
4. **Size.** Estimate while planning and count the final diff while reviewing:
   200-400 hand-written code lines per PR is the target, and about 500 is where
   a change counts as over. Tests, fixtures and checks fit within about twice
   the change's actual hand-written code unless the brief says why; docs and
   shipped agent-instruction prose (skills, fragments, prompts) count as
   hand-written code. These are steering signals, never caps: being over never
   stops work and never needs the user's approval, and does not fail this row;
   the row fails only a change that is over with neither a split nor a stated
   reason. If an estimate is over and a seam exists that a reviewer can read
   alone, split into stacked PRs without asking; each piece passes its checks on
   its own. If no seam exists, make one change and say why in the brief and PR
   summary.

Paste the file verbatim into the worker's and every reviewer's brief. A one-line
summary or "follow the project rules" is not a rubric.
