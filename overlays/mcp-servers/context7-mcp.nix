# context7-mcp — override nixpkgs to pin version with inline hashes.
#
# nixpkgs uses finalAttrs pattern where pnpmDeps reads from
# finalAttrs.{pname, version, src}. We override version + src +
# pnpmDeps hash; the fixed-point re-derives the rest.
#
# The tarball is unpacked into a directory via runCommandLocal so $src
# matches nixpkgs' fetchFromGitHub shape (the upstream installPhase
# references $src/skills). pnpmDepsHash is inlined.
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
  version = "2.1.7";
  # Unpack fetchurl tarball into a directory so $src is a directory
  # (matching nixpkgs' fetchFromGitHub shape).
  src = ourPkgs.runCommandLocal "context7-mcp-src-${version}" {} ''
    tar xf ${ourPkgs.fetchurl {
      url = "https://github.com/upstash/context7/archive/refs/tags/@upstash/context7-mcp@${version}.tar.gz";
      name = "context7--upstash-context7-mcp_${version}.tar.gz";
      hash = "sha256-0l42zdVNiyAQei9Fl29xNLBl74u74UA4zf7jZzsB7ME=";
    }}
    mv context7-* $out
  '';
in
  ourPkgs.context7-mcp.overrideAttrs (finalAttrs: _old: {
    inherit src version;
    # Tests require full pnpm workspace root; nixpkgs base has no checkPhase.
    pnpmDeps = ourPkgs.fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      fetcherVersion = 3;
      hash = "sha256-8RRHfCTZVC91T1Qx+ACCo2oG4ZwMNy5WYakCjmBhe3Q=";
    };
  })
