sources: final: prev: let
  nv = sources.git-branchless;

  # Pin to 1.88.0 — git-branchless v0.10.0 has esl01-indexedlog build
  # failure on Rust 1.89+ (arxanas/git-branchless#1585). Update this
  # when upstream fixes the issue or a new release ships.
  rust = final.rust-bin.stable."1.88.0".default;
  rustPlatform = final.makeRustPlatform {
    cargo = rust;
    rustc = rust;
  };
in {
  git-branchless = prev.git-branchless.override (_: {
    rustPlatform.buildRustPackage = args:
      rustPlatform.buildRustPackage (finalAttrs: let
        a = (final.lib.toFunction args) finalAttrs;
      in
        a
        // {
          inherit (nv) version src;
          cargoHash = nv.cargoHash;
          postPatch = null;
        });
  });
}
