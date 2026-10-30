# `ai.airlock.instances.<name>`: Airlock CONNECT proxies, the same on both
# backends apart from the default state root. The final Rust command reads the
# strict JSON document rendered at each start through `ai.services`.
#
# Every instance registers its origin for HTTP and HTTPS on the shared network
# proxy surface. Generic proxy resolution lives in lib/ai/proxy.nix.
backend: {
  config,
  lib,
  pkgs,
  ...
}: let
  caDirectory = "ca";
  # The CA directory, beside the rendered config in the runtime directory.
  caPath = ''"''${AIRLOCK_CONFIG%/*}/${caDirectory}"'';
  instances = import ../../ai-module/lib/instances.nix {inherit lib;};
  intercepting = instance: instance.settings.interception != null;
  owner = "airlock";
  trust = import ../lib/trust.nix {inherit caDirectory lib pkgs;};
  withoutNulls = lib.filterAttrs (_: value: value != null);
in {
  imports = [
    (instances.module {
      # An intercepting instance keeps its CA in the private runtime directory,
      # so it lives as long as that directory.
      arguments = instance:
        ''serve --config "$AIRLOCK_CONFIG"''
        + lib.optionalString (intercepting instance) " --ca-directory ${caPath}";
      inherit backend owner;
      defaultPort = 8318;
      derived = {instance, ...}: {listen = "127.0.0.1:${toString instance.port}";};
      packagePath = "airlock";
      packageText = import ../../../lib/ai/nat-package-text.nix {inherit lib;} "airlock";
      # `serve` only loads a CA; publishing runs `ca init` first, which creates it.
      preStart = instance: lib.optionalString (intercepting instance) (trust.publish instance.package);
      # Keep plain instances' config hashes stable: adding null fields would
      # change their service launchers and restart them on upgrade.
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
                  type = lib.types.nullOr lib.types.pathInStore;
                  default = null;
                  description = "A PEM certificate file under /nix/store for private origins or a corporate TLS-inspecting proxy. Mutable paths outside /nix/store are refused so a same-user client cannot rewrite upstream trust. Adding it widens trust beyond the system roots.";
                };
              };
            });
            default = null;
            description = "Selective TLS interception. The service runs `airlock ca init` on a CA directory in its private runtime directory before `serve` starts.";
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
        inherit (instance) enable;
        http = instances.origin instance;
        https = instances.origin instance;
        trust =
          if instance.settings.interception == null
          then null
          else trust.helper (instances.serviceName owner name);
      })
      config.ai.airlock.instances;
  };
}
