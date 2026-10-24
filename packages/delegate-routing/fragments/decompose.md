Before choosing execution, list the parts of the work. Size each part to a
reviewable step, a few hundred changed lines at most, never to a whole PR. Name
the files each part writes and what each part depends on.

Parts that write disjoint files may run at the same time in one worktree, with
one committer that stages and commits for all of them. Parts whose files
overlap, or that need different bases, get their own worktrees.

Plan a convergence stage. Join the parts, by stack or by rebase, run the
integrated review on the joined result, and only then open the PR. A
frontier-tier model does that final review, picked per the Work and review
workflow.
