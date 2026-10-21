# `ai.cliproxyapi.instances.<name>`: CLIProxyAPI daemons, the same on both
# backends apart from the default state root. The config is rendered at each
# start from the typed settings; CLIProxyAPI's own rewrites of it (the hashed
# management key, management API saves) reach only that copy. Its auth
# directory holds the OAuth logins it writes, so it lives in `stateDir`.
# CLIProxyAPI fetches its model catalogs and its management panel from the
# network unprompted; both default off here (see docs/cliproxyapi-settings.md).
backend: {lib, ...}: let
  inherit (import ../lib/default.nix {inherit lib;}) cliproxyapi;
in {
  imports = [
    ((import ../../ai-module/lib/instances.nix {inherit lib;}).module {
      # `--local-model` is the only switch for the model catalog fetches: it
      # selects the embedded catalogs, and no setting selects the embedded catalogs.
      arguments = instance:
        ''--config "$CPA_CONFIG"''
        + lib.optionalString (!instance.fetchModelCatalogs) " --local-model";
      inherit backend;
      defaultPort = 8317;
      derived = {instance, ...}: {
        # Without this the daemon downloads its control panel from GitHub at
        # start and every 3 hours after.
        management.disable-auto-update-panel = lib.mkDefault true;
        oauth.auth-dir = "${instance.stateDir}/auth";
        server = {
          host = lib.mkDefault "127.0.0.1";
          inherit (instance) port;
        };
      };
      directories = instance: ["${instance.stateDir}/auth"];
      extraOptions.fetchModelCatalogs = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether the daemon fetches its model catalogs from
          raw.githubusercontent.com and models.router-for.me at start and every
          3 hours. Off, it runs with `--local-model` and serves the catalogs
          embedded in the package; a `settings.models.*` source still takes
          precedence.
        '';
      };
      owner = "cliproxyapi";
      packagePath = "generic.cliproxyapi";
      packageText = import ../../../lib/ai/nat-package-text.nix {inherit lib;} "generic.cliproxyapi";
      inherit (cliproxyapi) render settingsType;
      tool = "CLIProxyAPI";
      variable = "CPA_CONFIG";
    })
  ];
}
