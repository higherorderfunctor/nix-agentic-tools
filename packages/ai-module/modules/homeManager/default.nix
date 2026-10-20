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
  secrets = import ../../lib/secrets.nix {inherit lib;} {
    backend = "hm";
    providers = config.ai.activationOrder.secretProviders;
    secretNodes = config.ai.activationOrder.secretNodes;
  };
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
        secretNodes = secrets.nodes;
      };
    home.file = files.native;
    systemd.user.services = services.hmUnits pkgs config.ai.services {
      providerUnits = secrets.units;
      userServices = config.systemd.user.services;
    };
    warnings = services.hmWarnings pkgs config.ai.services;
  };
}
