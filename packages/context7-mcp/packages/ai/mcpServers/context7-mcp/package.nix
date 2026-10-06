# context7-mcp — override nixpkgs to track main branch.
#
# nixpkgs uses finalAttrs pattern where pnpmDeps reads from
# finalAttrs.{pname, version, src}. We override version + src +
# pnpmDeps hash; the fixed-point re-derives the rest.
{
  pkgs,
  packageLib,
  ...
}: let
  vu = packageLib;

  rev = "72181dd4ac5ba5761ebcb3e4d04566e819293db6";
  src = pkgs.fetchFromGitHub {
    owner = "upstash";
    repo = "context7";
    inherit rev;
    hash = "sha256-WRZ41nhHAzaVcDF/kcP9Ww12N76cSlAKj3vOqLp6TfY=";
  };
in
  (pkgs.context7-mcp.override {pnpm_10 = pkgs.ai.generic.pnpm_10;}).overrideAttrs (finalAttrs: _prev: let
    # upstream: readPackageJsonVersion @ packages/mcp/package.json
    upstreamVersion = "4.1.1";
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
    pnpmDeps = pkgs.fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      pnpm = pkgs.ai.generic.pnpm_10;
      fetcherVersion = 3;
      hash = "sha256-aBLZ15M61DIaTz9OtQartJilwNZ5nxk6wDQT3B3sxbY=";
    };
  })
