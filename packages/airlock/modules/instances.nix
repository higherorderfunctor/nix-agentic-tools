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
  # Home Manager's user manager sets XDG_RUNTIME_DIR, which Airlock uses by
  # default; devenv gives each project its own runtime root instead.
  home =
    if backend == "devenv"
    then "${config.devenv.runtime}/airlock"
    else null;
  instances = import ../../ai-module/lib/instances.nix {inherit lib;};
  intercepting = instance: instance.settings.interception != null;
  # An intercepting instance's CA lives in the runtime directory Airlock
  # derives from the instance name, so it lasts as long as that directory.
  # Airlock refuses any other name; evaluation refuses it before a start does.
  instanceArgument = instance:
    lib.optionalString (intercepting instance) (
      if builtins.match "[A-Za-z0-9_-]+" instance.name == null
      then throw "ai.airlock.instances.${instance.name}: an intercepting instance's name must be ASCII letters, digits, `_` or `-`, because it names the CA's runtime directory"
      else " --instance ${lib.escapeShellArg instance.name}"
    );
  withoutNulls = lib.filterAttrs (_: value: value != null);
in {
  imports = [
    (instances.module {
      arguments = instance: ''serve --config "$AIRLOCK_CONFIG"'' + instanceArgument instance;
      inherit backend;
      defaultPort = 8318;
      derived = {instance, ...}: {listen = "127.0.0.1:${toString instance.port}";};
      owner = "airlock";
      packagePath = "airlock";
      packageText = import ../../../lib/ai/nat-package-text.nix {inherit lib;} "airlock";
      # `serve` only loads a CA, so `ca init` creates it before `serve` starts.
      preStart = instance:
        lib.optionalString (intercepting instance)
        "${lib.getExe instance.package} ca init${instanceArgument instance}";
      # Keep plain instances' config hashes stable: adding null fields would
      # change their service launchers and restart them on upgrade.
      render = settings: {
        content = builtins.toJSON (withoutNulls {
          inherit (settings) listen;
          interception = lib.mapNullable withoutNulls settings.interception;
        });
        environment = lib.optionalAttrs (home != null && settings.interception != null) {AIRLOCK_HOME = home;};
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
            description = "Selective TLS interception. The service runs `airlock ca init --instance <name>` before `serve` starts; the CA lives in `$XDG_RUNTIME_DIR/airlock/<name>` on Home Manager and under the devenv runtime root on devenv.";
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
