The worker does the task to the rubric. For a failing check, test or bug, a
read-only delegate records the root cause with evidence; the orchestrator
validates it, and a different delegate fixes against that diagnosis. Reviewers
check the written diagnosis against the change.

Open every writer and fixer brief with a hard-rules block before the task. It
gives the literal worktree path every command starts in. It forbids commit,
push, rebase, branch change and git configuration, because the orchestrator
commits. It names the project's coding standards, the checks the writer may and
may not run, the files it may read, and the report's evidence format. When
commit hooks reject patterns writers are known to produce, the brief names each
pattern and its required form, and has the writer run that linter on every
edited file.

Split a brief that needs one section per surface into one writer run per
surface, and a surface with several units into one run per unit. Run them in
sequence when they share a worktree, and commit each before the next.
