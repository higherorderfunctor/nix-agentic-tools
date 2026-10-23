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

  rev = "b5e81de845092694ba1bfc5af15400f319c89b6d";
  src = pkgs.fetchFromGitHub {
    owner = "upstash";
    repo = "context7";
    inherit rev;
    hash = "sha256-17LQ/6OcUQUqhGPk4jFLvV7S57Fp9kzNrOjo780n7wY=";
  };
in
  (pkgs.context7-mcp.override {pnpm_10 = pkgs.ai.generic.pnpm_10;}).overrideAttrs (finalAttrs: _prev: let
    # upstream: readPackageJsonVersion @ packages/mcp/package.json
    upstreamVersion = "4.4.4";
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
      hash = "sha256-/y0hL+S7cUeZ2QxtjJ75ihIGYjOEskycUybYDp4hEck=";
    };
  })
