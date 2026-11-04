# Both selection and relay lowering resolve the same pins and SSH defaults.
{lib}: overrides: let
  builtinsForges = import ../../../git-relay/lib/forges.nix;
in
  lib.genAttrs (lib.unique (builtins.attrNames builtinsForges ++ builtins.attrNames overrides)) (host:
    {
      hostKeys = null;
      sshPort = 22;
      sshUser = "git";
    }
    // (builtinsForges.${host} or {})
    // lib.filterAttrs (_: value: value != null) (overrides.${host} or {}))
