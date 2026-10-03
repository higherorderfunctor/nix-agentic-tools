{
  imports = [./checks/module-eval.nix];
  testing.moduleProbes = [
    {
      ai = {
        kimchi.programs.delegate-routing.models = [{vendors = ["anthropic"];}];
        kiro.programs.delegate-routing.models = [{vendors = ["anthropic"];}];
        programs.delegate-routing.enable = true;
      };
    }
  ];
}
