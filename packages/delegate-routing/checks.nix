{
  imports = [./checks/module-eval.nix];
  testing.moduleProbes = [
    {
      ai = {
        kiro.programs.delegate-routing.models = [{vendors = ["anthropic"];}];
        programs.delegate-routing.enable = true;
      };
    }
  ];
}
