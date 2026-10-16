{
  config,
  lib,
  pkgs,
  ...
}: let
  files = import ../../lib/files/backend.nix {inherit lib pkgs;} {
    backend = "hm";
    inherit config;
    root = "$HOME";
    stateRoot = "\${XDG_STATE_HOME:-$HOME/.local/state}/nix-agentic-tools";
  };
  duplicate = files.duplicate ["files2-apply" "files2-prune"];
  generated =
    {files2-prune = files.prune;}
    // lib.optionalAttrs (files.plan != []) {
      files2-apply = files.generatedEntry {
        after = ["files"] ++ lib.optionals files.usesRun ["secrets"];
        afterNodes = {
          devenv = [];
          hm = ["ai2-files2-prune"];
        };
        before = ["materialized"];
        command = files.phase "apply";
      };
    };
in {
  imports = [../common.nix];
  config = {
    home.activation = assert lib.assertMsg (duplicate == null) "ai.activation2.${duplicate}: reserved generated entry";
      import ../../lib/lower-hm.nix {inherit lib pkgs;} {
        entries = generated // config.ai.activation2;
        hmLib = lib;
        # HM's DAG tolerates a missing dependency, so the conventional sops-nix
        # entry is always an edge; a module may not define root ai.* defaults.
        secretNodes = lib.unique (["sops-nix"] ++ config.ai.activation2Order.secretNodes);
      };
    home.file = files.native;
  };
}
