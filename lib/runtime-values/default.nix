{lib}: let
  inherit (import ./classify.nix {inherit lib;}) classify;
in {
  inherit classify;
}
