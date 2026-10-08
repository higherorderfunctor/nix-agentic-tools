# Keep the public curried API; configuration only creates a bin-only launcher.
{
  lib,
  pkgs,
}: package: requested:
(import ./launcher.nix {inherit lib pkgs;}) {
  inherit package;
  spec = requested;
}
