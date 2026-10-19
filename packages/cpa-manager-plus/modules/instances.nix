# `ai.cpa-manager-plus.instances.<name>`: CPA Manager Plus daemons, the same on
# both backends apart from the default state root. config.json is rendered at
# each start and `CPA_MANAGER_CONFIG` points at it; the key-carrying variables
# stay redact references in the service environment. `upstream` names the
# CLIProxyAPI instance it manages.
backend: {
  config,
  lib,
  ...
}: let
  inherit (import ../lib/default.nix {inherit lib;}) cpa-manager-plus;
  instances = import ../../ai-module/lib/instances.nix {inherit lib;};
  select = top: name: instance:
    instances.select {
      instances = top.ai.cliproxyapi.instances;
      name = instance.upstream;
      option = "ai.cpa-manager-plus.instances.${name}.upstream";
      owner = "cliproxyapi";
    };
in {
  imports = [
    (instances.module {
      arguments = "";
      inherit backend;
      defaultPort = 18317;
      # Native defaults would bind every interface and keep the data next to
      # the config, in the launcher's runtime directory.
      derived = {
        config,
        instance,
        name,
      }: let
        selected =
          if instance.upstream == null
          then {}
          else select config name instance;
        key = lib.attrByPath ["management" "secret-key"] null config.ai.cliproxyapi.instances.${instance.upstream}.settings;
      in {
        config =
          {
            dataDir = instance.stateDir;
            httpAddr = "127.0.0.1:${toString instance.port}";
          }
          // lib.optionalAttrs (selected ? url) {cpaUpstreamUrl = lib.mkDefault selected.url;};
        environment = lib.optionalAttrs (selected ? url && key != null) {CPA_MANAGEMENT_KEY = lib.mkDefault key;};
      };
      extraOptions.upstream = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "main";
        description = ''
          The `ai.cliproxyapi.instances` entry this instance manages. It
          defaults `settings.config.cpaUpstreamUrl` to that instance's
          loopback origin and `settings.environment.CPA_MANAGEMENT_KEY` to its
          `settings.management.secret-key` reference.
        '';
      };
      owner = "cpa-manager-plus";
      packagePath = "generic.cpa-manager-plus";
      packageText = import ../../../lib/ai/nat-package-text.nix {inherit lib;} "generic.cpa-manager-plus";
      inherit (cpa-manager-plus) render settingsType;
      tool = "CPA Manager Plus";
      variable = "CPA_MANAGER_CONFIG";
    })
  ];

  config.assertions = lib.concatLists (lib.mapAttrsToList (name: instance:
    lib.optional (instance.enable && instance.upstream != null) (let
      selected = select config name instance;
    in {
      assertion = selected ? url;
      message = selected.problem or "";
    }))
  config.ai.cpa-manager-plus.instances);
}
