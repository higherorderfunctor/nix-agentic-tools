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

  rev = "9a384f099011d6299df530fd8d7a22510b2004d5";
  src = ourPkgs.fetchFromGitHub {
    owner = "upstash";
    repo = "context7";
    inherit rev;
    hash = "sha256-r2df2yePheeU6dPj5JX0NIFNtj5jy7xmvd+dU0GHR3E=";
  };
in
  ourPkgs.context7-mcp.overrideAttrs (finalAttrs: _prev: let
    # upstream: readPackageJsonVersion @ packages/mcp/package.json
    upstreamVersion = "4.0.3";
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
      hash = "sha256-1ZrQ+GMGgBNyycp/Xp2/meGwxaWTh+c53qgaEy30dl8=";
    };
  })
