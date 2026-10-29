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
  # The CA directory, beside the rendered config in the runtime directory.
  caPath = ''"''${AIRLOCK_CONFIG%/*}/ca"'';
  instances = import ../../ai-module/lib/instances.nix {inherit lib;};
  intercepting = instance: instance.settings.interception != null;
  withoutNulls = lib.filterAttrs (_: value: value != null);
in {
  imports = [
    (instances.module {
      # An intercepting instance keeps its CA in the private runtime directory,
      # so it lives as long as that directory.
      arguments = instance:
        ''serve --config "$AIRLOCK_CONFIG"''
        + lib.optionalString (intercepting instance) " --ca-directory ${caPath}";
      inherit backend;
      defaultPort = 8318;
      derived = {instance, ...}: {listen = "127.0.0.1:${toString instance.port}";};
      owner = "airlock";
      packagePath = "airlock";
      packageText = import ../../../lib/ai/nat-package-text.nix {inherit lib;} "airlock";
      # `serve` only loads a CA, so `ca init` creates it before `serve` starts.
      preStart = instance:
        lib.optionalString (intercepting instance)
        "${lib.getExe instance.package} ca init ${caPath}";
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
      lib.mapAttrs (_: instance: {
        inherit (instance) enable;
        http = instances.origin instance;
        https = instances.origin instance;
      })
      config.ai.airlock.instances;
  };
}
