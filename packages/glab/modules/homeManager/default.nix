# glab home-manager module — user-global install.
#
# Option DECLARATIONS live in ../options.nix, shared with the devenv
# facet so the two cannot drift. This file owns the HM-side wiring: default the
# package out of the overlay, put the wrapped glab on the user's PATH, and
# optionally lower keyring synchronization into activation + systemd user
# units.
#
# Picked up by `collectFacet ["modules" "homeManager"]` in flake.nix.
{
  config,
  lib,
  options,
  pkgs,
  ...
}: let
  cfg = config.glab;
  effectiveConfigDir =
    if cfg.configDir != null
    then cfg.configDir
    else "${config.xdg.configHome}/glab-cli";
  keyringPendingDir = "${config.xdg.stateHome}/glab";
  keyringPendingFile = "${keyringPendingDir}/keyring-sync-pending";
  keyringSync = import ../../lib/mkKeyringSync.nix {
    configDir = effectiveConfigDir;
    inherit cfg lib pkgs;
    pendingFile = keyringPendingFile;
  };
  wrappedGlab = import ../../lib/mkGlab.nix {inherit cfg lib pkgs;};
in {
  imports = [(import ../options.nix {inherit lib;})];

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = !cfg.keyringSync.enable || cfg.enable;
          message = "glab.keyringSync.enable requires glab.enable.";
        }
        {
          assertion = !cfg.keyringSync.enable || pkgs.stdenv.isLinux;
          message = "glab.keyringSync.enable currently requires Linux Secret Service and systemd user units.";
        }
        {
          assertion = !cfg.keyringSync.enable || cfg.host != null;
          message = "glab.keyringSync.enable requires glab.host so the token cannot be stored for the wrong instance.";
        }
        {
          assertion =
            !cfg.keyringSync.enable
            || (cfg.token != null && !(cfg.token ? plain));
          message = "glab.keyringSync.enable requires glab.token.file or glab.token.helper; token.plain would already expose the token through the Nix store.";
        }
      ];
    }
    (lib.mkIf cfg.enable {
      glab.package = lib.mkDefault pkgs.ai.devTools.glab;

      home.packages = [
        wrappedGlab
      ];
    })
    (lib.mkIf (cfg.enable && lib.hasAttrByPath ["ai" "codex" "internal"] options && config.ai.codex.enable) {
      ai.codex.internal._integration_writable_roots = lib.mkAfter [effectiveConfigDir];
    })
    (lib.mkIf (cfg.enable && cfg.keyringSync.enable && pkgs.stdenv.isLinux) {
      # Activation records one attempt without touching the secret. The path
      # unit remains dormant outside a graphical session, then consumes this
      # marker exactly once. The service removes it on EVERY exit, so a locked
      # or cancelled keyring cannot become a prompt loop.
      home.activation.glabKeyringSync = lib.hm.dag.entryAfter ["linkGeneration" "sops-nix"] ''
        (
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :

        run ${pkgs.coreutils}/bin/mkdir -p -m 0700 ${lib.escapeShellArg keyringPendingDir}
        run ${pkgs.coreutils}/bin/touch ${lib.escapeShellArg keyringPendingFile}
        )
      '';

      systemd.user.paths.glab-keyring-sync = {
        Unit = {
          Description = "Queue glab keyring synchronization after graphical login";
          PartOf = ["graphical-session.target"];
        };
        Path = {
          PathExists = keyringPendingFile;
          Unit = "glab-keyring-sync.service";
        };
        Install.WantedBy = ["graphical-session.target"];
      };

      systemd.user.services.glab-keyring-sync = {
        Unit = {
          After = ["graphical-session.target"];
          Description = "Synchronize glab authentication into the OS keyring";
          PartOf = ["graphical-session.target"];
        };
        Service = {
          ExecStart = keyringSync.script;
          Restart = "no";
          TimeoutStartSec = "5min";
          Type = "oneshot";
          UMask = "0077";
        };
      };
    })
  ];
}
