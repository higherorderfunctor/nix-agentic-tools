{
  forges,
  identities,
  lib,
  pkgs,
  runtime,
}:
lib.concatMapAttrs (identity: settings:
    lib.mapAttrs (_token: remote: let
      forge = forges.${remote.forge};
    in {
      inherit identity;
      credential = "${runtime}-${identity}";
      inherit (remote) forge;
      knownHosts = pkgs.writeText "sandbox-${runtime}-${remote.forge}-known-hosts" forge.hostKeys;
      inherit (forge) sshPort sshUser;
    })
    settings.remotes)
identities
