# Full recommended git configuration for stacked commit workflows.
#
# Includes Required + Strongly Recommended + Recommended settings.
#
# Usage in home-manager:
#   programs.git.settings = inputs.stacked-workflow-skills.lib.gitConfigFull;
#
# Or via the home-manager module (applies mkDefault to each leaf):
#   stacked-workflows = { enable = true; gitPreset = "full"; };
#
# See references/recommended-config.md for explanations of each setting.
let
  base = import ./git-config.nix;
in
  # Shallow merge (//) at the top level. Keys present in both `base` and this
  # attrset must be explicitly deep-merged (e.g., branchless = base.branchless // { ... }).
  # If adding a new key that also exists in base, merge it the same way.
  base
  // {
    # ── Recommended: git-branchless ────────────────────────────────────

    branchless =
      base.branchless
      // {
        navigation.autoSwitchBranches = true;
        next.interactive = true;
        restack.preserveTimestamps = true;
        smartlog.defaultRevset = "(@ % main()) | stack() | descendants(@) | @";
        test = {
          jobs = 0;
          strategy = "worktree";
        };
      };

    # ── Recommended: git-revise ────────────────────────────────────────

    revise.autoSquash = true;

    # ── Recommended: general git ───────────────────────────────────────

    commit.verbose = true;

    diff = {
      algorithm = "histogram";
      colorMoved = "plain";
      mnemonicPrefix = true;
    };

    fetch = {
      all = true;
      prune = true;
      pruneTags = true;
    };

    push = {
      autoSetupRemote = true;
      followTags = true;
    };

    tag.sort = "version:refname";
  }
