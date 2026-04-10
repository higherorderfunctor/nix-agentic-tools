# context7-mcp — override nixpkgs to pin nvfetcher-tracked version.
#
# nixpkgs uses finalAttrs pattern (stdenv.mkDerivation finalAttrs: { ... })
# where pnpmDeps reads from finalAttrs.{pname, version, src}. We override
# version + src + pnpmDeps hash; the fixed-point re-derives the rest.
#
# Source is fetched via fetchFromGitHub (not nvfetcher) because the scoped
# npm tag `@upstash/context7-mcp@<ver>` has `@` characters that nvfetcher's
# fetchgit can't handle. Hashes are in hashes.json (srcHash, pnpmDepsHash).
# nvfetcher tracks the version from npm.
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
in
  # Two-arg overrideAttrs: finalAttrs is the new fixed-point (sees
  # overridden version + src), old is the previous attrs.
  ourPkgs.context7-mcp.overrideAttrs (finalAttrs: _old: {
    inherit (nv) version;
    src = ourPkgs.fetchFromGitHub {
      owner = "upstash";
      repo = "context7";
      rev = "refs/tags/@upstash/context7-mcp@${finalAttrs.version}";
      hash = nv.srcHash;
    };
    # fetchPnpmDeps reads finalAttrs.src (the overridden GitHub source).
    # Same function call as nixpkgs — just our hash.
    pnpmDeps = ourPkgs.fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      fetcherVersion = 3;
      hash = nv.pnpmDepsHash;
    };
  })
