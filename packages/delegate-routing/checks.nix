{
  imports = [./checks/module-eval.nix];
  testing.moduleProbes = [
    {
      ai = {
        # The provenance helpers enable every runtime, and delegate-routing
        # asserts each enabled one selects a family. These selections only
        # keep the probe config valid.
        kimchi.programs.delegate-routing.models = [{vendors = ["anthropic"];}];
        kiro.programs.delegate-routing.models = [{vendors = ["anthropic"];}];
        programs.delegate-routing.enable = true;
      };
    }
  ];
}
