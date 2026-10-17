# Daemon schema, launch-time environment and backend lowering share one source.
{lib}: let
  redact = import ../../../lib/redact {inherit lib;};
  strictShellApplication = import ../../../lib/strict-shell-application.nix;
  claimAssertions = claims:
    lib.concatLists (lib.mapAttrsToList (group: keys:
      lib.mapAttrsToList (key: owners: {
        assertion = builtins.length owners <= 1;
        message = "ai.claims.${group}.${key}: claimed by ${lib.concatStringsSep " and " (lib.sort lib.lessThan owners)}";
      })
      keys)
    claims);
  defaulted = type: default: lib.mkOption {inherit type default;};
  serviceEntry = lib.types.submodule {
    options = {
      command = lib.mkOption {type = lib.types.nonEmptyListOf lib.types.str;};
      enable = defaulted lib.types.bool true;
      environment = defaulted redact.types.environment {};
      ports = defaulted (lib.types.attrsOf lib.types.port) {};
      restart = defaulted (lib.types.enum ["always" "never" "on-failure"]) "on-failure";
      restartOnChange = defaulted (lib.types.listOf (lib.types.strMatching "/.*")) [];
    };
  };
  # Files whose content change restarts the service: the declared paths plus
  # every `redact.file` the environment reads.
  triggers = entry: lib.sort lib.lessThan (lib.unique (entry.restartOnChange ++ lib.concatMap redact.filePaths (builtins.attrValues entry.environment)));
  mkLauncher = {
    pkgs,
    name,
    entry,
  }:
    strictShellApplication pkgs {
      name = "ai-service-${name}";
      text = ''
        # Generated literal assignments: dollar signs and quotes are data.
        # shellcheck disable=SC2016,SC2089,SC2090
        {
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (variable: value:
          redact.assign {
            inherit pkgs value variable;
            export = true;
            option = "ai.services.${name}.environment.${variable}";
          })
        entry.environment)}
        :
        }
        # shellcheck disable=SC2016
        exec ${lib.escapeShellArgs entry.command}
      '';
    };
  enabled = lib.filterAttrs (_: entry: entry.enable);
  launch = pkgs: name: entry: "${mkLauncher {inherit pkgs name entry;}}/bin/ai-service-${name}";
  hmUnits = pkgs: services:
    lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (lib.mapAttrs (name: entry: {
      Install.WantedBy = ["default.target"];
      Service = {
        ExecStart = launch pkgs name entry;
        Restart =
          if entry.restart == "never"
          then "no"
          else entry.restart;
        RestartSec = 5;
      };
      Unit = {
        After = ["network.target"];
        Description = "${name} (ai.services)";
      };
    }) (enabled services));
  hmWarnings = pkgs: services: lib.optionals (!pkgs.stdenv.hostPlatform.isLinux) (map (name: "ai.services.${name}: Home Manager writes services as systemd user units, which this platform lacks; the service is not written") (builtins.attrNames (enabled services)));
  devenvProcesses = pkgs: services:
    lib.mapAttrs (
      name: entry:
        {
          exec = launch pkgs name entry;
          restart.on =
            if entry.restart == "on-failure"
            then "on_failure"
            else entry.restart;
        }
        // lib.optionalAttrs (triggers entry != []) {watch.paths = triggers entry;}
    ) (enabled services);
  # Home Manager has no live file watch: each activation hashes the readable
  # trigger files and restarts a running unit whose hash changed since the
  # recorded one. The first record restarts nothing, `try-restart` leaves a
  # stopped unit stopped, and a missing or unreadable file is skipped so an
  # secret that is not decrypted yet cannot abort activation.
  rotationCheck = pkgs: name: paths: ''
    hash_file="$state_dir/${name}.sha256"
    new_hash="$(
      for path in ${lib.escapeShellArgs paths}; do
        if [ -f "$path" ] && [ -r "$path" ]; then
          ${pkgs.coreutils}/bin/sha256sum -- "$path"
        fi
      done | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d ' ' -f1
    )"
    old_hash=""
    if [ -r "$hash_file" ]; then
      old_hash="$(${pkgs.coreutils}/bin/cat -- "$hash_file")"
    fi
    if [ -n "$old_hash" ] && [ "$old_hash" != "$new_hash" ]; then
      ${pkgs.systemd}/bin/systemctl --user try-restart ${lib.escapeShellArg name}
    fi
    printf '%s' "$new_hash" > "$hash_file"
  '';
  hmRestart = pkgs: services: let
    watched = lib.filterAttrs (_: paths: paths != []) (lib.mapAttrs (_: triggers) (enabled services));
  in
    lib.optionalAttrs (pkgs.stdenv.hostPlatform.isLinux && watched != {}) {
      services-restart-on-change = {
        after = ["files" "secrets"];
        before = ["shell"];
        command = ''
          case "$(${pkgs.systemd}/bin/systemctl --user is-system-running 2>/dev/null || :)" in
            running | degraded) ;;
            *) exit 0 ;;
          esac
          state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/nix-agentic-tools/services"
          ${pkgs.coreutils}/bin/mkdir -p "$state_dir"
          ${pkgs.coreutils}/bin/chmod 700 "$state_dir"
          ${lib.concatStringsSep "\n" (lib.mapAttrsToList (rotationCheck pkgs) watched)}
        '';
      };
    };
in {
  inherit claimAssertions devenvProcesses hmRestart hmUnits hmWarnings mkLauncher serviceEntry triggers;
}
