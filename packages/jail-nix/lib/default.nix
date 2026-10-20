# jail.nix (sourcehut ~alexdavid/jail.nix) is a pure Nix library, not a
# package: `init pkgs` and `extend {pkgs; ...}` return a `jail name exe
# permissions` builder. Both take the CALLER's pkgs, like `ai.mkSandbox`.
{inputs, ...}: {
  ai.jail = import ./jail.nix {inherit inputs;};
}
