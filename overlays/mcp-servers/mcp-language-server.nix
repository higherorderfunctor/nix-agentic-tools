# mcp-language-server — override nixpkgs to pin nvfetcher-tracked version.
#
# nixpkgs uses finalAttrs pattern with buildGoModule + proxyVendor.
# We override version + src + vendorHash; the fixed-point re-derives
# the rest.
#
# Instantiates `ourPkgs` from `inputs.nixpkgs` for cache-hit parity
# (see dev/fragments/overlays/overlay-pattern.md).
{
  inputs,
  final,
  nv,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  # nvfetcher gives "v0.1.1"; nixpkgs expects "0.1.1"
  version = ourPkgs.lib.removePrefix "v" nv.version;
in
  ourPkgs.mcp-language-server.overrideAttrs (_finalAttrs: _old: {
    inherit version;
    inherit (nv) src vendorHash;
  })
