# Upstream's recipe called with the composer-supplied pkgs, never upstream's
# own package output (unlike semble, there is no prebuilt cache to preserve
# for a shell script). The flake input owns updates.
{
  inputs,
  pkgs,
  ...
}:
pkgs.callPackage "${inputs.microvm}/pkgs/microvm-command.nix" {}
