{
  forges,
  identities,
  lib,
  runtime,
}:
lib.concatMapAttrs (identity: settings:
    lib.mapAttrs (_token: remote: let
      forge = forges.${remote.forge};
    in {
      inherit identity;
      credential = "${runtime}-${identity}";
      inherit (remote) forge;
      inherit (forge) sshPort sshUser;
    })
    settings.remotes)
identities
