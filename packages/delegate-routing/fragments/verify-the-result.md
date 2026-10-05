Give each delegate one clear goal and say what result proves it's done. Require
an evidence chain for every claim it reports: file and line, or the exact
command and its output. Each claim comes back as verified, retracted (checked
and not an issue, with the reason), or unknown (not checked, with what would
settle it). Delegates never drop a claim silently.

At each level of orchestration, judge those claims before passing them up.
Re-run the commands the important claims depend on. An exit code of 0 alone
isn't proof. Check whatever depends on the changed files, such as generated
files and tests. When something fails, name why: a concept problem needs a
stronger model, missing evidence needs fetching, an execution slip needs fixing.
Fix small things yourself, and drop what turned out not to be an issue. Bring
the user only what's real and needs their decision, written the way their
communication rules ask, if they have any.
