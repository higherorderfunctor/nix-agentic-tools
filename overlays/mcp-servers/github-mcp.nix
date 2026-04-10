# github-mcp — override nixpkgs to pin nvfetcher-tracked version.
#
# nixpkgs uses finalAttrs pattern with buildGoModule. We override
# version + src + vendorHash; the fixed-point re-derives ldflags
# and the rest.
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
  # nvfetcher gives "v0.32.0"; nixpkgs expects "0.32.0"
  version = ourPkgs.lib.removePrefix "v" nv.version;
in
  ourPkgs.github-mcp-server.overrideAttrs (_finalAttrs: _old: {
    inherit version;
    inherit (nv) src vendorHash;
  })
