# `ai.airlock.instances.<name>`: Airlock CONNECT proxies, the same on both
# backends apart from the default state root. The final Rust command reads the
# strict JSON document rendered at each start through `ai.services`.
#
# Every instance registers its origin for HTTP and HTTPS on the shared network
# proxy surface. Generic proxy resolution lives in lib/ai/proxy.nix.
backend: {
  config,
  lib,
  ...
}: let
  instances = import ../../ai-module/lib/instances.nix {inherit lib;};
in {
  imports = [
    (instances.module {
      arguments = _: ''serve --config "$AIRLOCK_CONFIG"'';
      inherit backend;
      defaultPort = 8318;
      derived = {instance, ...}: {listen = "127.0.0.1:${toString instance.port}";};
      owner = "airlock";
      packagePath = "airlock";
      packageText = import ../../../lib/ai/nat-package-text.nix {inherit lib;} "airlock";
      render = settings: {
        content = builtins.toJSON {inherit (settings) listen;};
        secrets = {};
      };
      settingsType = lib.types.submodule {
        options.listen = lib.mkOption {
          type = lib.types.str;
          description = "The strict JSON listen address. The instance fixes it to `127.0.0.1:<port>`.";
        };
      };
      tool = "Airlock";
      variable = "AIRLOCK_CONFIG";
    })
  ];

  # The claim keeps an instance name unique across proxy owners.
  config.ai = {
    airlock.claims.proxy-instance = builtins.attrNames config.ai.airlock.instances;
    internal.proxyInstances =
      lib.mapAttrs (_: instance: {
        inherit (instance) enable;
        http = instances.origin instance;
        https = instances.origin instance;
      })
      config.ai.airlock.instances;
  };
}
