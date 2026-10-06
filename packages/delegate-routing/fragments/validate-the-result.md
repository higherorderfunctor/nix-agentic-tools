Give each delegate one clear goal and say what result proves it's done. Require
an evidence chain for every claim it reports: file and line, or the exact
command and its output. Each claim comes back as verified, retracted (checked
and not an issue, with the reason), or unknown (not checked, with what would
settle it). Delegates never drop a claim silently.

At each level of orchestration, validate those claims before passing them up.
Pick the check the claim needs:

- A claim that rests on a command: re-run it, or have a separate step re-run it.
  An exit code of 0 alone isn't proof. Check what depends on the changed files,
  such as generated files and tests.
- A claim that rests on reading: judge it with the full picture you hold. A
  finding that only looks wrong from the reviewer's narrower scope, for example
  two things that "conflict" where one is deliberately scoped, is retracted with
  the reason, not escalated.

When something fails, name why: a concept problem needs a stronger model,
missing evidence needs fetching, an execution slip needs fixing. Fix small
things yourself. Bring the user only what is real and needs their decision,
written the way their communication rules ask, if they have any.
