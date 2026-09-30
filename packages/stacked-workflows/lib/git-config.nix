# Recommended git configuration for stacked commit workflows.
#
# Git-key shaped: `<section>.<key>`. ../modules/options.nix applies it as
# sugar over the `git.*` options, the tools' sections (`absorb`, `branchless`,
# `revise`) to their typed settings and everything else to `git.settings`, so
# a key here that is not a typed option fails evaluation.
#
# No `branchless.core.mainBranch`: `git branchless init` writes the detected
# main branch into every repository it initializes, so a user-global value is
# dead there, and a repository-local one would force `main` onto a `master`
# repository. `init.defaultBranch` below still steers init's detection.
{
  # ── Required ──────────────────────────────────────────────────────

  init.defaultBranch = "main";

  # ── Strongly Recommended ──────────────────────────────────────────

  absorb = {
    fixupTargetAlwaysSHA = true;
    maxStack = 50;
    oneFixupPerCommit = true;
  };

  merge.conflictStyle = "zdiff3";

  pull.rebase = true;

  rebase = {
    autoSquash = true;
    autoStash = true;
    updateRefs = true;
  };

  rerere = {
    autoupdate = true;
    enabled = true;
  };
}
