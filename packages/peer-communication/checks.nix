{
  imports = [./checks/module-eval.nix];
  testing.moduleProbes = [{ai.programs.peer-communication.enable = true;}];
}
