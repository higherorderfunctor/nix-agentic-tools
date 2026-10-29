# `ai.airlock.instances.<name>`: Airlock CONNECT proxies, the same on both
# backends apart from the default state root. The final Rust command reads the
# strict JSON document rendered at each start through `ai.services`.
#
# Every instance is also a clientless proxy instance (lib/ai/proxy): a Harness
# selects it by name with `ai.<runtime>.proxy.instance`, and the runtime's
# `airlock` lowering points it at the instance's loopback origin. An
# intercepting instance also registers the trust helper that hands a client
# its CA.
backend: {
  config,
  lib,
  pkgs,
  ...
}: let
  instances = import ../../ai-module/lib/instances.nix {inherit lib;};
  trust = import ../lib/trust.nix {inherit lib pkgs;};
  withoutNulls = lib.filterAttrs (_: value: value != null);
in {
  imports = [
    (instances.module {
      # An intercepting instance keeps its CA beside the rendered config, in
      # the private runtime directory, so it lives as long as that directory.
      arguments = instance:
        ''serve --config "$AIRLOCK_CONFIG"''
        + lib.optionalString (instance.settings.interception != null) " --ca-directory \"\${AIRLOCK_CONFIG%/*}/ca\"";
      inherit backend;
      defaultPort = 8318;
      derived = {instance, ...}: {listen = "127.0.0.1:${toString instance.port}";};
      owner = "airlock";
      packagePath = "airlock";
      packageText = import ../../../lib/ai/nat-package-text.nix {inherit lib;} "airlock";
      # Unset options are left out, so a plain instance's file holds only `listen`.
      render = settings: {
        content = builtins.toJSON (withoutNulls {
          inherit (settings) listen;
          interception = lib.mapNullable withoutNulls settings.interception;
        });
        secrets = {};
      };
      settingsType = lib.types.submodule {
        options = {
          interception = lib.mkOption {
            type = lib.types.nullOr (lib.types.submodule {
              options = {
                destinations = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  description = "Exact `DNS-name:port` destinations to intercept. Airlock refuses invalid or duplicate entries before listening.";
                };
                upstream_roots = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "A PEM certificate file added to the system upstream trust roots, such as a store path.";
                };
              };
            });
            default = null;
            description = "Selective TLS interception. The CA lives in the service's private runtime directory and is created or validated before listening.";
          };
          listen = lib.mkOption {
            type = lib.types.str;
            description = "The strict JSON listen address. The instance fixes it to `127.0.0.1:<port>`.";
          };
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
      lib.mapAttrs (name: instance: {
        backend = "airlock";
        inherit (instance) enable;
        trust =
          if instance.settings.interception == null
          then null
          else trust "airlock-${name}";
        url = instances.origin instance;
      })
      config.ai.airlock.instances;
  };
}
