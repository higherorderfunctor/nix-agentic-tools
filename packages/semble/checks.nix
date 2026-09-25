{
  imports = [./checks/models.nix ./checks/module-eval.nix ./checks/semble-templates.nix];
  testing.moduleProbes = [{ai.programs.semble.enable = true;}];
}
