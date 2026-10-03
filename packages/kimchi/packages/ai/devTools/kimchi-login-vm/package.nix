{
  inputs,
  kimchi,
  system,
  ...
}: let
  guest = inputs.nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      inputs.microvm.nixosModules.microvm
      ./guest.nix
      # Use the same pinned Kimchi derivation exported by the repository overlay.
      {environment.systemPackages = [kimchi];}
    ];
  };
in
  guest.config.microvm.declaredRunner.overrideAttrs (old: {
    meta =
      (old.meta or {})
      // {
        description = "Throwaway headless NixOS guest for Kimchi browser login testing";
        platforms = import ./platforms.nix;
      };
    passthru =
      (old.passthru or {})
      // {
        updateFlakeInput = "microvm";
      };
  })
