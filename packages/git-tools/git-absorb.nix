# `{inputs}` is threaded through by packages/git-tools/default.nix
# so Phase 3.3 can switch build inputs to
# `ourPkgs = import inputs.nixpkgs { ... }` for cache-hit parity.
# Not yet consumed in this file; plumbing-only for now.
_: sources: final: prev: let
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
          inherit (nv) cargoHash;
        });
  });
}
