{
  forges,
  identities,
  lib,
  runtime,
}: let
  credentialName = import ./credential.nix;
in
  lib.concatMapAttrs (identity: settings:
    lib.mapAttrs (_token: remote: let
      forge = forges.${remote.forge};
    in {
      inherit identity;
      credential = credentialName runtime identity;
      inherit (remote) forge;
      inherit (forge) sshPort sshUser;
    })
    settings.remotes)
  identities
