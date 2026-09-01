# Full recommended git configuration for stacked commit workflows.
#
# Includes Required + Strongly Recommended + Recommended settings.
#
# Usage in home-manager:
#   programs.git.settings = inputs.stacked-workflow-skills.lib.gitConfigFull;
#
# Or via the home-manager module (applies mkDefault to each leaf):
#   ai.programs.stacked-workflows.enable = true;
#   stacked-workflows.gitPreset = "full";
#
# See packages/stacked-workflows/references/recommended-config.md for explanations of each setting.
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
        # `jobs` is a memory bound, not a CPU tuning knob, and it is only
        # a live question because `strategy = worktree` below makes fan-out
        # possible at all. `0` means one job per PHYSICAL CPU, each in its
        # own worktree with no shared build or evaluation cache, so peak
        # usage is jobs x per-job footprint: seven concurrent
        # `nix flake check` evaluators measured ~24 GB and OOM-killed a
        # 30 GB workstation. This preset used to say 0. `1` restores the
        # upstream default and is stated explicitly so the pairing with
        # `strategy` is legible. `--jobs N` overrides it in both directions
        # when a cheaper test command can afford more, and mkDefault is
        # applied per leaf, so raise it in `programs.git.settings` per
        # machine.
        test = {
          jobs = 1;
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
