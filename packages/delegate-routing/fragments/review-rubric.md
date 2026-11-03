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

Paste the file verbatim into the worker's and every reviewer's brief. A one-line
summary or "follow the project rules" is not a rubric.
