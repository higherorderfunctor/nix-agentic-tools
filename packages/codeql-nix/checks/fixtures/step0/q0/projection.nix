{job}: let
  adapter = builtins.fetchTree (job.moduleArguments.nixql // {type = "path";});
  library = builtins.fetchTree (job.moduleArguments.nixpkgs // {type = "path";});
in
  import (adapter.outPath + "/src/eval/nix/modules.nix") {
    lib = import (library.outPath + "/lib");
    modules =
      [./options.nix ./ordinary.nix]
      ++ {
        equal = [./equal.nix];
        failure = [./failure.nix];
        ordinary = [./default.nix];
        unselected = [./unselected.nix];
      }.${
        job.moduleArguments.case
      };
    inherit job;
  }
