sources: final: prev: let
  nv = sources.git-absorb;

  rustPlatform = final.makeRustPlatform {
    cargo = final.rust-bin.stable.latest.default;
    rustc = final.rust-bin.stable.latest.default;
  };
in {
  git-absorb = prev.git-absorb.override (_: {
    rustPlatform.buildRustPackage = args:
      rustPlatform.buildRustPackage (finalAttrs: let
        a = (final.lib.toFunction args) finalAttrs;
      in
        a
        // {
          inherit (nv) version src;
          cargoHash = nv.cargoHash;
        });
  });
}
