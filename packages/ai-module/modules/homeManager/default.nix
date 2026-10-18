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
  services = import ../../lib/services.nix {inherit lib;};
  restart = services.hmRestart pkgs config.ai.services;
  duplicate = files.duplicate ["files-apply" "files-prune" "services-restart-on-change"];
  generated =
    {files-prune = files.prune;}
    // lib.mapAttrs (_: files.generatedEntry) restart
    // lib.optionalAttrs (files.plan != []) {
      files-apply = files.generatedEntry {
        after = ["files"] ++ lib.optionals files.usesRun ["secrets"];
        afterNodes = {
          devenv = [];
          hm = ["ai-files-prune"];
        };
        before = ["materialized"];
        command = files.phase "apply";
      };
    };
in {
  imports = [../common.nix];
  config = {
    home.activation = assert lib.assertMsg (duplicate == null) "ai.activation.${duplicate}: reserved generated entry";
      import ../../lib/lower-hm.nix {inherit lib pkgs;} {
        entries = generated // config.ai.activation;
        hmLib = lib;
        # HM's DAG tolerates a missing dependency, so the conventional sops-nix
        # entry is always an edge; a module may not define root ai.* defaults.
        secretNodes = lib.unique (["sops-nix"] ++ config.ai.activationOrder.secretNodes);
      };
    home.file = files.native;
    systemd.user.services = services.hmUnits pkgs config.ai.services;
    warnings = services.hmWarnings pkgs config.ai.services;
  };
}
