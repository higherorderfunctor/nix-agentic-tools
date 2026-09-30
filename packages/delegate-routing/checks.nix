{
  imports = [./checks/module-eval.nix];
  testing.moduleProbes = [{ai.programs.delegate-routing.enable = true;}];
}
