# Recommended git configuration for stacked commit workflows.
#
# Usage in home-manager:
#   programs.git.settings = inputs.stacked-workflow-skills.lib.gitConfig;
#
# Or via the home-manager module (applies mkDefault to each leaf):
#   stacked-workflows = { enable = true; gitPreset = "minimal"; };
#
# See references/recommended-config.md for explanations of each setting.
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
