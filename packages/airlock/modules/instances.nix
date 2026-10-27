# `ai.airlock.instances.<name>`: Airlock CONNECT proxies, the same on both
# backends apart from the default state root. The final Rust command reads the
# strict JSON document rendered at each start through `ai.services`.
backend: {
  config,
  lib,
  ...
}: let
  instances = import ../../ai-module/lib/instances.nix {inherit lib;};
  redact = import ../../../lib/redact {inherit lib;};
  renderer = import ../../../lib/extracted/render.nix {inherit lib;};
in {
  imports = [
    (instances.module {
      arguments = instance:
        lib.concatStringsSep " " (
          [''serve --config "$AIRLOCK_CONFIG"'']
          # The CA lives beside the rendered config, in the runtime directory.
          ++ lib.optional (instance.settings.interception != null) ''--ca-directory "''${AIRLOCK_CONFIG%/*}/ca"''
        );
      inherit backend;
      defaultPort = 8318;
      derived = {instance, ...}: {listen = "127.0.0.1:${toString instance.port}";};
      owner = "airlock";
      packagePath = "airlock";
      packageText = import ../../../lib/ai/nat-package-text.nix {inherit lib;} "airlock";
      render = settings:
        renderer.render {
          prefix = "AIRLOCK";
          settings = {
            inherit (settings) interception listen;
            clients =
              if settings.clients == null
              then null
              else lib.mapAttrs (_: client: {token_file = client.token;}) settings.clients;
          };
        };
      settingsType = lib.types.submodule {
        options = {
          clients = lib.mkOption {
            type = lib.types.nullOr (lib.types.attrsOf (lib.types.submodule {
              options.token = lib.mkOption {
                type = redact.types.secretFile;
                description = "Client token as a redact reference, copied to a private runtime file at service start.";
              };
            }));
            default = null;
            description = "Named proxy clients. Null preserves unauthenticated operation; an empty map fails Airlock startup.";
          };
          interception = lib.mkOption {
            type = lib.types.nullOr (lib.types.submodule {
              options = {
                destinations = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  description = "Exact DNS-name:port destinations to intercept. Airlock validates names, ports and duplicates before listening.";
                };
                upstream_roots = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Optional PEM certificate file added to the native upstream trust roots.";
                };
              };
            });
            default = null;
            description = "Selective TLS interception. The service keeps its CA beside the private runtime config and initializes it before listening.";
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

  # CPA instance names share this group, so `ai.proxy.instance` names exactly
  # one owner's instance.
  config.ai.airlock.claims.proxy-instance = builtins.attrNames config.ai.airlock.instances;
}
