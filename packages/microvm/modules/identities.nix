{inheritOptions}: {
  config,
  lib,
  ...
}: let
  redact = import ../../../lib/redact {inherit lib;};
  resolveForges = import ../lib/sandbox/forges.nix {inherit lib;};
  runtimeNames = import ../../../lib/ai/runtimes.nix;
  upstream = import ../../git-relay/lib/upstream.nix {inherit lib;};
  gitOptions = {
    forges = lib.mkOption {
      default = {};
      description = "Forge pins and SSH endpoint defaults, merged per non-null field over the relay's built-in forge facts. A runtime definition replaces the whole root forges set.";
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          hostKeys = lib.mkOption {
            default = null;
            description = "Pinned known_hosts lines; null retains built-in pins when available. Custom forges require non-empty pins.";
            type = lib.types.nullOr lib.types.lines;
          };
          sshPort = lib.mkOption {
            default = null;
            description = "Default SSH port; null uses 22. An ssh:// URL's port wins.";
            type = lib.types.nullOr lib.types.port;
          };
          sshUser = lib.mkOption {
            default = null;
            description = "Default SSH user; null uses git. An SSH URL's user wins.";
            type = lib.types.nullOr lib.types.str;
          };
        };
      });
    };
    identities = lib.mkOption {
      default = {};
      description = "Git identities selected by the remote URL's exact host token. A runtime definition REPLACES the whole ai.sandbox.git.identities set; explicitly inherit desired root entries and omit unwanted identities.";
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          push.key = lib.mkOption {
            description = "Required push key as a redact reference; delivered only to the relay, never copied from the host identity.";
            type = redact.types.secretFile;
          };
          remotes = lib.mkOption {
            default = {};
            description = "URL host tokens exactly as written, including SSH aliases; ~/.ssh/config is never consulted.";
            type = lib.types.attrsOf (lib.types.submodule ({name, ...}: {
              options.forge = lib.mkOption {
                default = name;
                description = "Real forge host, defaulting to this URL token; requires built-in or explicit forge pins.";
                type = lib.types.str;
              };
            }));
          };
          signing.key = lib.mkOption {
            default = null;
            description = "Optional signing key as a redact reference. Declared only: phase 5 consumes it; null means unsigned commits and no agent door.";
            type = lib.types.nullOr redact.types.secretFile;
          };
          user = {
            email = lib.mkOption {
              description = "Required guest Git author and committer email.";
              type = lib.types.str;
            };
            name = lib.mkOption {
              description = "Required guest Git author and committer name.";
              type = lib.types.str;
            };
          };
        };
      });
    };
  };
  active = builtins.filter (runtime: config.ai.${runtime}.enable && config.ai.${runtime}.sandbox.enable) runtimeNames;
  validate = path: git: let
    forges = resolveForges git.forges;
    validHost = host: builtins.match upstream.hostPattern host != null;
  in
    lib.mapAttrsToList (host: _: {
      assertion = validHost host;
      message = "${path}.forges.\"${host}\": a forge host must be a DNS name or IPv4 address.";
    })
    git.forges
    ++ lib.concatLists (lib.mapAttrsToList (identity: entry:
      lib.concatLists (lib.mapAttrsToList (token: remote: [
          {
            assertion = validHost token;
            message = "${path}.identities.${identity}.remotes.\"${token}\": a URL token must be a DNS name or IPv4 address.";
          }
          {
            assertion = validHost remote.forge;
            message = "${path}.identities.${identity}.remotes.\"${token}\".forge: a forge host must be a DNS name or IPv4 address.";
          }
          {
            assertion = (forges.${remote.forge}.hostKeys or null) != null && builtins.match "[[:space:]]*" forges.${remote.forge}.hostKeys == null;
            message = "${path}.identities.${identity}.remotes.\"${token}\".forge requires pins in ${path}.forges.\"${remote.forge}\".hostKeys or the relay's built-in forge facts.";
          }
        ])
        entry.remotes))
    git.identities);
in {
  options.ai =
    {sandbox.git = gitOptions;}
    // lib.genAttrs runtimeNames (_: {sandbox.git = inheritOptions ["git"] gitOptions;});

  config = {
    ai.claims.sandbox-remote = lib.mkMerge (map (runtime:
      lib.mkMerge (lib.mapAttrsToList (identity: entry:
        lib.mapAttrs' (token: _: lib.nameValuePair "${runtime}:${token}" ["ai.${runtime}.sandbox.git.identities.${identity}"]) entry.remotes)
      config.ai.${runtime}.sandbox.git.identities))
    active);
    assertions =
      validate "ai.sandbox.git" config.ai.sandbox.git
      ++ lib.concatMap (runtime: validate "ai.${runtime}.sandbox.git" config.ai.${runtime}.sandbox.git) runtimeNames;
  };
}
