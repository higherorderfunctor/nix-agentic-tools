# context7-mcp — override nixpkgs to pin nvfetcher-tracked version.
#
# nixpkgs uses finalAttrs pattern where pnpmDeps reads from
# finalAttrs.{pname, version, src}. We override version + src +
# pnpmDeps hash; the fixed-point re-derives the rest.
#
# nvfetcher tracks version from GitHub tags + fetches the archive
# via fetchurl (tarball). We unpack it into a directory so $src
# matches nixpkgs' fetchFromGitHub shape (the upstream installPhase
# references $src/skills). pnpmDepsHash is in hashes.json.
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
  # Unpack nvfetcher's fetchurl tarball into a directory so $src
  # is a directory (matching nixpkgs' fetchFromGitHub shape).
  src = ourPkgs.runCommandLocal "context7-mcp-src-${nv.version}" {} ''
    tar xf ${nv.src}
    mv context7-* $out
  '';
in
  ourPkgs.context7-mcp.overrideAttrs (finalAttrs: _old: {
    inherit src;
    inherit (nv) version;
    pnpmDeps = ourPkgs.fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      fetcherVersion = 3;
      hash = nv.pnpmDepsHash;
    };
  })
