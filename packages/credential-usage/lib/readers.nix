# Standalone callers merge Reader contributions the way Home Manager and devenv
# do. delegate-routing's content package calls it to resolve its Claude usage
# command; each caller names the owner modules that contribute.
{
  lib,
  pkgs,
}: {
  contributions,
  overrides ? {},
}:
(lib.evalModules {
  specialArgs = {inherit lib pkgs;};
  modules =
    [
      ../modules/common.nix
      # Owner contributions read this flake's package tree through the same key
      # a backend module offers them.
      {options.ai.internal.packages = lib.mkOption {type = lib.types.raw;};}
      # This flake's build unless the overlay is applied (ai.internal.packages).
      {
        ai.internal.packages = pkgs.ai or (throw "ai.credential-usage.mergeReaders: pass a package set that carries this flake's ai root");
      }
      {ai.credentialUsage.readers = overrides;}
    ]
    ++ contributions;
}).config.ai.credentialUsage.readers
