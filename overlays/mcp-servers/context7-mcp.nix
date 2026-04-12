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

  rev = "00833f92623032dd643974048f9817dd0f1694cc";
  src = ourPkgs.fetchFromGitHub {
    owner = "upstash";
    repo = "context7";
    inherit rev;
    hash = "sha256-ML6yCceOPlX8pcDeUPfnSkzfJwMB4oScZgulXh6CgrA=";
  };
in
  ourPkgs.context7-mcp.overrideAttrs (finalAttrs: _prev: {
    version = vu.mkVersion {
      upstream = vu.readPackageJsonVersion "${src}/packages/mcp/package.json";
      inherit rev;
    };
    inherit src;
    doCheck = true;
    checkPhase = ''
      runHook preCheck
      pnpm --filter @upstash/context7-mcp run test
      runHook postCheck
    '';
    # Override version check — binary reports upstream version without our +shortRev suffix
    installCheckPhase = let
      upstreamVersion = vu.readPackageJsonVersion "${src}/packages/mcp/package.json";
    in ''
      runHook preInstallCheck
      echo "Executing custom version check for MCP stdio server..."
      output=$(< /dev/null $out/bin/context7-mcp 2>&1 || true)
      if echo "$output" | grep -Fq "v${upstreamVersion}"; then
        echo "versionCheckPhase: found version v${upstreamVersion}"
      else
        echo "versionCheckPhase: failed to find version v${upstreamVersion}"
        echo "Output was:"
        echo "$output"
        exit 1
      fi
      runHook postInstallCheck
    '';
    pnpmDeps = ourPkgs.fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      fetcherVersion = 3;
      hash = "sha256-MHKzlxlyvQoLvoLomhToaZgnPU7H6iHLmokhotZF6VY=";
    };
  })
