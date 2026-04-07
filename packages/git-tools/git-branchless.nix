# `{inputs}` is threaded through by packages/git-tools/default.nix
# so Phase 3.3 can switch build inputs to
# `ourPkgs = import inputs.nixpkgs { ... }` for cache-hit parity.
# Not yet consumed in this file; plumbing-only for now.
_: sources: final: prev: let
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
          # Strip "v" prefix — nvfetcher gives "v0.10.0" from the tag
          # but the binary prints "0.10.0" in --version output.
          version = final.lib.removePrefix "v" nv.version;
          inherit (nv) src;
          inherit (nv) cargoHash;
          postPatch = null;
        });
  });
}
