{
  inputs,
  lib,
  ...
}: {
  ai.mkSandbox = import ./mkSandbox.nix {inherit inputs lib;};
}
