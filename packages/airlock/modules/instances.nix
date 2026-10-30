# `ai.airlock.instances.<name>`: Airlock CONNECT proxies, the same on both
# backends apart from the default state root.
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
      arguments = instance: "serve --listen 127.0.0.1:${toString instance.port}";
      inherit backend;
      defaultPort = 8318;
      owner = "airlock";
      packagePath = "airlock";
      packageText = import ../../../lib/ai/nat-package-text.nix {inherit lib;} "airlock";
      tool = "Airlock";
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
