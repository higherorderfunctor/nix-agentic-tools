{
  imports = [./checks/module-eval.nix];
  testing.moduleProbes = [{ai.programs.git-worktrees.enable = true;}];
}
