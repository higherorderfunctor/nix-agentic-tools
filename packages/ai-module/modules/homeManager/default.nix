{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [../common.nix];
  config = {
    home.activation = import ../../lib/lower-hm.nix {inherit lib pkgs;} {
      entries = config.ai.activation2;
      hmLib = lib;
      # HM's DAG tolerates a missing dependency, so the conventional sops-nix
      # entry is always an edge; a module may not define root ai.* defaults.
      secretNodes = lib.unique (["sops-nix"] ++ config.ai.activation2Order.secretNodes);
    };
  };
}
