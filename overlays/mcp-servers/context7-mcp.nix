# context7-mcp — override nixpkgs to track main branch.
#
# nixpkgs uses finalAttrs pattern where pnpmDeps reads from
# finalAttrs.{pname, version, src}. We override version + src +
# pnpmDeps hash; the fixed-point re-derives the rest.
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
  vu = import ../lib.nix;

  rev = "0b190c1b8db81c9d16f2d390e228422a679a8bc4";
  src = ourPkgs.fetchFromGitHub {
    owner = "upstash";
    repo = "context7";
    inherit rev;
    hash = "sha256-PAWUqhH6+OQXRB96ul9P3xYXXiiydZeB4um1t77X4C4=";
  };
in
  ourPkgs.context7-mcp.overrideAttrs (finalAttrs: _prev: let
    upstreamVersion = vu.readPackageJsonVersion "${src}/packages/mcp/package.json";
  in {
    version = vu.mkVersion {
      upstream = upstreamVersion;
      inherit rev;
    };
    inherit src;
    doCheck = true;
    checkPhase = ''
      runHook preCheck
      pnpm --filter @upstash/context7-mcp run test
      runHook postCheck
    '';
    # Patch versionCheckHook's $version to drop our +<shortRev> suffix.
    # The upstream binary reports just "2.1.8", so matching against
    # our "2.1.8+c31528d" fails. preVersionCheck fires inside the hook
    # before the comparison — override $version there to the upstream
    # portion so the check still runs (just against the right string).
    preVersionCheck = ''
      version="${upstreamVersion}"
    '';
    pnpmDeps = ourPkgs.fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      fetcherVersion = 3;
      hash = "sha256-MHKzlxlyvQoLvoLomhToaZgnPU7H6iHLmokhotZF6VY=";
    };
  })
