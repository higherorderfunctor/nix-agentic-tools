{
  imports = [./checks/module-eval.nix];
  testing.moduleProbes = [{ai.programs.delegate-sizing.enable = true;}];
}
