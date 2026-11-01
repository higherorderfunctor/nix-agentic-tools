# `ai.git-relay.instances.<name>`: git relay daemons, the same on both
# backends apart from the default state root. The JSON config is rendered at
# each start and `GIT_RELAY_CONFIG` points at it; `sshKeyFile` is a secret
# file the launcher writes, so the key never reaches the store.
backend: {
  config,
  lib,
  ...
}: let
  redact = import ../../../lib/redact {inherit lib;};
  instances = import ../../ai-module/lib/instances.nix {inherit lib;};
  # A repository name becomes a directory and a URL path.
  nameType = "[A-Za-z0-9_][A-Za-z0-9._-]*";
  settingsType = lib.types.submodule {
    options = {
      knownHosts = lib.mkOption {
        type = lib.types.nullOr lib.types.lines;
        # GitHub's ed25519 host key, from `gh api meta` (.ssh_keys), pinned so
        # the forward cannot be redirected.
        default = ''
          github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
        '';
        description = ''
          `known_hosts` text the forward trusts, with strict host key checking.
          Null leaves the daemon user's own known hosts in force.
        '';
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
          options.upstream = lib.mkOption {
            type = lib.types.str;
            example = "git@github.com:owner/repo.git";
            description = "The URL every push to this repository is forwarded to.";
          };
        });
        default = {};
        description = ''
          Repositories served as `git://<listen>:<port>/<name>.git`. Each push
          is forwarded to its upstream whole, and refused when the forward
          fails.
        '';
      };
      sshKeyFile = lib.mkOption {
        type = lib.types.nullOr redact.types.secretFile;
        default = null;
        description = ''
          The private key the forward pushes with, as a redact reference. The
          service launcher writes it to a 0600 file and the forward reads that
          file. Null forwards without an ssh identity, for an upstream that
          needs none.
        '';
      };
    };
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

  config.assertions = lib.concatLists (lib.mapAttrsToList (instanceName: instance:
    lib.mapAttrsToList (name: _: {
      assertion = builtins.match nameType name != null;
      message = "ai.git-relay.instances.${instanceName}.settings.repositories.${name}: a repository name starts with a letter, digit or `_` and holds only letters, digits, `.`, `_` and `-`, since it becomes a directory and a URL path.";
    })
    instance.settings.repositories)
  config.ai.git-relay.instances);
}
