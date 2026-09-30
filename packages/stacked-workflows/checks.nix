{
  imports = [./checks/module-eval.nix ./checks/scenarios.nix];
  testing.moduleProbes = [{ai.programs.stacked-workflows.enable = true;}];
}
