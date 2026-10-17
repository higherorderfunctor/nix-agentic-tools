{
  imports = [./checks/models.nix ./checks/module-eval.nix ./checks/package-identity.nix ./checks/semble-extracted.nix ./checks/semble-templates.nix ./checks/worker-mappings.nix];
  testing.moduleProbes = [{ai.programs.semble.enable = true;}];
}
