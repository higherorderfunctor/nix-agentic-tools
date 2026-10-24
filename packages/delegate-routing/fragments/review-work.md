The worker does the task to the rubric. When fixing a failing check, test or
bug, separate diagnosis from fix: a read-only delegate records the root cause
with evidence, the orchestrator validates it, and a different delegate fixes
against that diagnosis. This prevents the fixer from redefining the failure to
call the task done. Reviewers check against the written diagnosis, not the
fixer's account.
