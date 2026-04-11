# mcp-language-server — override nixpkgs to pin inline-sourced version.
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
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
in
  ourPkgs.mcp-language-server.overrideAttrs (_finalAttrs: _old: {
    version = "unstable-2025-06-03";
    src = ourPkgs.fetchFromGitHub {
      owner = "isaacphi";
      repo = "mcp-language-server";
      rev = "e4395849a52e18555361abab60a060802c06bf50";
      hash = "sha256-INyzT/8UyJfg1PW5+PqZkIy/MZrDYykql0rD2Sl97Gg=";
    };
    vendorHash = "sha256-5YUI1IujtJJBfxsT9KZVVFVib1cK/Alk73y5tqxi6pQ=";
  })
