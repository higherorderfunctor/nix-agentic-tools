{
  backend,
  routed,
}: {
  config,
  lib,
  ...
}: let
  resolveForges = import ../lib/sandbox/forges.nix {inherit lib;};
  # Reuse common.nix's guest routes without depending on the claims registry,
  # whose service claims depend on the relay instance generated here.
  active = builtins.filter (runtime: config.ai.${runtime}.sandbox.git.identities != {}) routed;
  settings = runtime: let
    git = config.ai.${runtime}.sandbox.git;
    forges = resolveForges git.forges;
    hosts = identity: lib.unique (map (remote: remote.forge) (builtins.attrValues identity.remotes));
  in {
    credentials = lib.mapAttrs' (identity: entry:
      lib.nameValuePair "${runtime}-${identity}" {
        forges = lib.mkDefault (hosts entry);
        sshKeyFile = lib.mkDefault entry.push.key;
      })
    git.identities;
    forges = map (host: {
      ${host} = {
        # Beat the relay's built-in mkDefault pins while leaving native consumer
        # definitions (priority 100) authoritative.
        hostKeys = lib.mkOverride 900 forges.${host}.hostKeys;
      };
    }) (lib.unique (lib.concatMap hosts (builtins.attrValues git.identities)));
  };
  pinsByHost = lib.groupBy (pin: pin.host) (lib.concatMap (runtime:
    lib.concatMap (forge:
      lib.mapAttrsToList (host: _: {
        inherit host runtime;
        pins = (resolveForges config.ai.${runtime}.sandbox.git.forges).${host}.hostKeys or null;
      })
      forge)
    (settings runtime).forges)
  active);
in {
  config = lib.mkIf (active != []) {
    ai.git-relay.instances.sandbox = {
      port = lib.mkDefault (
        if backend == "devenv"
        then 19419
        else 19418
      );
      settings = {
        credentials = lib.mkMerge (map (runtime: (settings runtime).credentials) active);
        # A lines option concatenates equal definitions too; emit each pin
        # definition once when multiple runtimes use the same forge.
        forges = lib.mkMerge (lib.unique (lib.concatMap (runtime: (settings runtime).forges) active));
        sessions = lib.mkDefault true;
      };
    };
    # A native settings override must not turn the guest's relay into a door
    # to predictable static repository names.
    assertions =
      lib.mapAttrsToList (host: pins: {
        assertion = lib.all (pin: pin.pins == (builtins.head pins).pins) pins;
        message =
          "Sandbox relay requires identical resolved hostKeys for shared forge ${host}: "
          + lib.concatMapStringsSep " and " (pin: ''ai.${pin.runtime}.sandbox.git.forges."${host}".hostKeys'') pins;
      })
      pinsByHost
      ++ [
        {
          assertion = config.ai.git-relay.instances.sandbox.settings.sessions == true;
          message = "ai.git-relay.instances.sandbox.settings.sessions must be true: sandbox guests require a session-only relay.";
        }
      ];
  };
}
