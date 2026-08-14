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

  rev = "0e3298e6435f2506e26477d0798441b7ff4d1014";
  src = ourPkgs.fetchFromGitHub {
    owner = "upstash";
    repo = "context7";
    inherit rev;
    hash = "sha256-aRD1zQFLeLo9SaSt0XrHn5XmuzPOVLRxCtbMyNP3h5U=";
  };
in
  ourPkgs.context7-mcp.overrideAttrs (finalAttrs: _prev: let
    # upstream: readPackageJsonVersion @ packages/mcp/package.json
    upstreamVersion = "4.0.2";
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
      pnpm = ourPkgs.pnpm_10;
      fetcherVersion = 3;
      hash = "sha256-F3c2/y3fgtPiUQOsg3hFdAp9b85AFs2mCTO1Eoa0i5E=";
    };
  })
