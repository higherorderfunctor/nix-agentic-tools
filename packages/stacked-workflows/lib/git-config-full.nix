# Full recommended git configuration for stacked commit workflows.
#
# Includes Required + Strongly Recommended + Recommended settings. Both module
# backends consume this file; backend-specific delivery belongs in the modules.
let
  base = import ./git-config.nix;
in
  # Shallow merge (//) at the top level. A section present in both `base` and
  # this attrset must be deep-merged explicitly (`absorb = base.absorb // {…}`).
  base
  // {
    # ── Recommended: git-branchless ──────────────────────────────────

    branchless = {
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
      # when a cheaper test command can afford more. Home Manager applies
      # mkDefault per leaf, while repository-local Git configuration wins
      # over an identical global value without changing the result.
      test = {
        jobs = 1;
        strategy = "worktree";
      };
    };

    # ── Recommended: git-revise ─────────────────────────────────────

    revise.autoSquash = true;

    # ── Recommended: general git ─────────────────────────────────────

    commit.verbose = true;

    diff = {
      algorithm = "histogram";
      colorMoved = "plain";
      mnemonicPrefix = true;
    };

    # No `pruneTags`: it deletes every local tag without a remote
    # counterpart, from every worktree, on any fetch, including the backup
    # tag a pre-rebase workflow just made.
    fetch = {
      all = true;
      prune = true;
    };

    push = {
      autoSetupRemote = true;
      followTags = true;
    };

    tag.sort = "version:refname";
  }
