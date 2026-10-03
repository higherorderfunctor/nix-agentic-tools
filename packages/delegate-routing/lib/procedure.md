## procedure

1. Write the rubric from operator-approved examples and give it to the writer
   and judge.
2. Before assigning a change, decide whether to extend an existing abstraction
   or replace it.
3. Set a hard cap before starting: three writer/reviewer rounds by default.
4. Classify each failure: conceptual, missing evidence, execution, unclear
   standard or done. Step up the model for conceptual failures; fetch missing
   evidence; repair execution failures. Clarify unclear standards with the
   operator. Stop when done.
5. Judge correctness and readability separately. Check calibration,
   actionability, precision, recall and stopping. Return accept, revise or
   insufficient evidence with a localized reason.
6. Escalate after two rounds with the same defect. Change the brief; do not
   reset the cap. At the cap, return the artifact, remaining defects and needed
   decision to the operator.

### review routing

1. Pick the writer's model and effort first.
2. Default: writer, then one reviewer. The reviewer uses a different model at
   the same or a higher tier, with the same or higher effort.
3. Escalate to prosecute, defend, judge when you intend to dismiss a reviewer
   finding, or the change touches a shared abstraction (library code or an
   option declaration). Prosecutor and defender are separate delegates; the
   judge rules on each finding from the evidence. At most three rounds; surface
   a split rather than deciding it yourself.
4. With two reviewers, take the union of their findings and adjudicate each one;
   never intersect them.
5. Review for subtraction. Writers default to additive change: they wrap an old
   implementation to keep its tests and docs passing instead of rewriting it.
   Treat existing tests and docs as evidence of intent, not contracts. If the
   code can collapse into something simpler, say so, and check whether the call
   paths a guard protects exist: grep the callers and trust CI for what it
   covers. A wrapper, shim, compatibility branch, or test kept only to preserve
   an old shape is a finding. Writers are weak at this and judges are good at
   it, so the judge owns it.
