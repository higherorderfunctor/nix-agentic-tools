# Recommended git configuration for stacked commit workflows.
#
# Both the Home Manager and devenv modules consume this attrset. Keep preset
# values here so the user-global and repository-local projections cannot drift.
{
  # ── Required ──────────────────────────────────────────────────────

  branchless.core.mainBranch = "main";

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
