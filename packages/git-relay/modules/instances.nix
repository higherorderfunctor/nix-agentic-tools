# cspell:ignore Codeberg
# `ai.git-relay.instances.<name>`: git relay daemons, the same on both
# backends apart from the default state root. The JSON config is rendered at
# each start and `GIT_RELAY_CONFIG` points at it; each credential is a secret
# file the service launcher writes, so keys never reach the store.
backend: {
  config,
  lib,
  ...
}: let
  redact = import ../../../lib/redact {inherit lib;};
  instances = import ../../ai-module/lib/instances.nix {inherit lib;};
  upstream = import ../lib/upstream.nix {inherit lib;};
  # A repository name becomes a directory and a URL path.
  nameType = "[A-Za-z0-9_][A-Za-z0-9._-]*";
  settingsType = lib.types.submodule {
    options = {
      credentials = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            forges = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              description = "The upstream hosts this credential may forward to. Every push re-reads the current config, so removing a host revokes pushes to it without deleting the key or the repository.";
            };
            sshKeyFile = lib.mkOption {
              type = redact.types.secretFile;
              description = "The push key as a redact reference; ai.services delivers its path in a 0600 runtime file.";
            };
          };
        });
        default = {};
        description = "Named SSH credentials, resolved from the current config for every push so removing one revokes it.";
      };
      forges = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options.hostKeys = lib.mkOption {
            type = lib.types.lines;
            description = "Pinned known_hosts lines for this upstream host; the relay never trusts host or user SSH configuration.";
          };
        });
        default = {};
        description = "Forge pins merged per host over Codeberg, GitHub and GitLab defaults; consumer hostKeys replace that host's pins.";
      };
      listen = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "The address the daemon binds. The git protocol has no authentication, so anything that reaches it can push.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        description = "The port the daemon listens on, fixed by the instance's `port`.";
      };
      repositories = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            credential = lib.mkOption {
              type = lib.types.str;
              description = "The settings.credentials entry whose SSH key forwards this repository's pushes.";
            };
            upstream = lib.mkOption {
              type = lib.types.str;
              example = "git@github.com:owner/repo.git";
              description = "The SSH URL (ssh:// or [user@]host:path) every push is forwarded to; its host needs forge pins.";
            };
          };
        });
        default = {};
        description = ''
          Repositories served as `git://<listen>:<port>/<name>.git`. Each push
          is forwarded to its upstream whole, and refused when the forward
          fails.
        '';
      };
      sessions = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = ''
          Whether this instance serves only per-session repositories under
          `stateDir/repositories/sessions`, created by `git-relay session
          open` while its caller holds `flock` on `stateDir/locks/<token>`; a
          session is served without a daemon restart. Such an instance serves
          no static repositories. `null` (the default) and `false` keep
          serving the static `repositories`.
        '';
      };
    };
    # Define each built-in leaf at default priority so another host does not
    # discard the built-ins, and a consumer can replace one host's pins.
    config.forges = lib.mapAttrs (_: forge: {
      hostKeys = lib.mkDefault forge.hostKeys;
    }) (import ../lib/forges.nix);
  };
  render = settings:
    (import ../../../lib/extracted/render.nix {inherit lib;}).render {
      prefix = "GIT_RELAY";
      inherit settings;
    };
in {
  imports = [
    (instances.module {
      inherit backend render settingsType;
      defaultPort = 19418;
      derived = {instance, ...}: {inherit (instance) port;};
      owner = "git-relay";
      packagePath = "generic.git-relay";
      packageText = import ../../../lib/ai/nat-package-text.nix {inherit lib;} "generic.git-relay";
      tool = "git-relay";
      variable = "GIT_RELAY_CONFIG";
    })
  ];

  config.assertions = lib.concatLists (lib.mapAttrsToList (instanceName: instance: let
    inherit (instance) settings;
    option = "ai.git-relay.instances.${instanceName}.settings";
  in
    lib.optional (settings.sessions == true) {
      assertion = settings.repositories == {};
      message = "${option}.sessions: a session-only instance serves no repositories; keep static repositories on another instance.";
    }
    ++ lib.mapAttrsToList (host: _: {
      assertion = builtins.match upstream.hostPattern host != null;
      message = "${option}.forges.${host}: a forge host must be a DNS name or IPv4 address, since it names a pin file.";
    })
    settings.forges
    ++ lib.concatLists (lib.mapAttrsToList (credential: entry:
      lib.imap0 (index: host: {
        assertion = builtins.match upstream.hostPattern host != null;
        message = "${option}.credentials.${credential}.forges.${toString index}: a forge host must be a DNS name or IPv4 address, to match an upstream host.";
      })
      entry.forges)
    settings.credentials)
    ++ lib.concatLists (lib.mapAttrsToList (name: repository: let
        host = upstream.host repository.upstream;
        location = "${option}.repositories.${name}";
      in [
        {
          assertion = builtins.match nameType name != null;
          message = "${location}: a repository name starts with a letter, digit or `_` and holds only letters, digits, `.`, `_` and `-`, since it becomes a directory and a URL path.";
        }
        {
          assertion = builtins.hasAttr repository.credential settings.credentials;
          message = "${location}.credential: `${repository.credential}` must name a defined settings.credentials entry.";
        }
        {
          assertion = host != null;
          message = "${location}.upstream: only SSH upstreams (ssh:// or [user@]host:path with a DNS name or IPv4 address) are supported.";
        }
        {
          assertion = host == null || (builtins.hasAttr host settings.forges && builtins.match "[[:space:]]*" settings.forges.${host}.hostKeys == null);
          message = "${location}.upstream: the upstream host must have pins in ${option}.forges.\"${toString host}\".hostKeys.";
        }
        {
          assertion =
            host
            == null
            || !builtins.hasAttr repository.credential settings.credentials
            || builtins.elem host settings.credentials.${repository.credential}.forges;
          message = "${location}.upstream: the upstream host must be listed in ${option}.credentials.${repository.credential}.forges, which every push re-reads.";
        }
      ])
      settings.repositories))
  config.ai.git-relay.instances);
}
