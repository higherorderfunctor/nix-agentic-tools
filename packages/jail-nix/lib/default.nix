# jail.nix (sourcehut ~alexdavid/jail.nix) is a pure Nix library, not a
# package: `init pkgs` and `extend {pkgs; ...}` return a `jail name exe
# permissions` builder. Both take the CALLER's pkgs, like `ai.mkSandbox`.
{inputs, ...}: {
  ai.jail = {
    inherit (inputs.jail-nix.lib) extend init;
    src = inputs.jail-nix.outPath;
  };
}
