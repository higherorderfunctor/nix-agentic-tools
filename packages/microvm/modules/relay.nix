{
  backend,
  routed,
}: {
  config,
  lib,
  ...
}: let
  credentialName = import ../lib/sandbox/credential.nix;
  resolveForges = import ../lib/sandbox/forges.nix {inherit lib;};
  # Reuse common.nix's guest routes without depending on the claims registry,
  # whose service claims depend on the relay instance generated here.
  active = builtins.filter (runtime: config.ai.${runtime}.sandbox.git.identities != {}) routed;
  identitiesOf = runtime: config.ai.${runtime}.sandbox.git.identities;
  hosts = identity: lib.unique (map (remote: remote.forge) (builtins.attrValues identity.remotes));
  # The relay keeps one pin set per forge host; pins are declared at the root only.
  pins = resolveForges config.ai.sandbox.git.forges;
in {
  config = lib.mkIf (active != []) {
    ai.git-relay.instances.sandbox = {
      port = lib.mkDefault (
        if backend == "devenv"
        then 19419
        else 19418
      );
      settings = {
        credentials = lib.mkMerge (map (runtime:
          lib.mapAttrs' (identity: entry:
            lib.nameValuePair (credentialName runtime identity) {
              forges = lib.mkDefault (hosts entry);
              sshKeyFile = lib.mkDefault entry.push.key;
            })
          (identitiesOf runtime))
        active);
        # Beat the relay's built-in mkDefault pins while leaving native consumer
        # definitions (priority 100) authoritative.
        forges = lib.genAttrs (lib.unique (lib.concatMap (runtime: lib.concatMap hosts (builtins.attrValues (identitiesOf runtime))) active)) (host: {
          hostKeys = lib.mkOverride 900 pins.${host}.hostKeys;
        });
        sessions = lib.mkDefault true;
      };
    };
    # A native settings override must not turn the guest's relay into a door
    # to predictable static repository names.
    assertions = [
      {
        assertion = config.ai.git-relay.instances.sandbox.settings.sessions == true;
        message = "ai.git-relay.instances.sandbox.settings.sessions must be true: sandbox guests require a session-only relay.";
      }
    ];
  };
}
