# openmemory-mcp — builds from CaviraOSS/OpenMemory mono-repo.
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) buildNpmPackage bun fetchFromGitHub makeWrapper;
  vu = import ../lib.nix;

  rev = "2f30580a68c18fd087e5c85f981074b68fd2e58e";
  src = fetchFromGitHub {
    owner = "CaviraOSS";
    repo = "OpenMemory";
    inherit rev;
    hash = "sha256-1wgHufcIbN06/df491G4mKXttRBAigeg2GgUGR4kTsg=";
  };
in
  buildNpmPackage {
    pname = "openmemory-mcp";
    version = vu.mkVersion {
      # upstream: readPackageJsonVersion @ packages/openmemory-js/package.json
      upstream = "1.3.3";
      inherit rev;
    };
    inherit src;
    sourceRoot = "source/packages/openmemory-js";
    postUnpack = "chmod -R u+w source";
    npmDepsHash = "sha256-jYvuAPpU53V44FdNmcvxQRJu7cGQBJ+7MCZPspWQwMA=";
    # Source needs building (tsc). npm tarball had pre-built dist/.
    nativeBuildInputs = [makeWrapper];
    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/openmemory-mcp $out/bin
      cp -r bin dist node_modules package.json $out/lib/openmemory-mcp/
      makeWrapper ${bun}/bin/bun $out/bin/openmemory-mcp \
        --add-flags "$out/lib/openmemory-mcp/bin/opm.js" \
        --add-flags "mcp"
      makeWrapper ${bun}/bin/bun $out/bin/openmemory-mcp-serve \
        --add-flags "$out/lib/openmemory-mcp/bin/opm.js" \
        --add-flags "serve"
      runHook postInstall
    '';
    doInstallCheck = true;
    installCheckPhase = vu.mkMcpSmokeTest {bin = "openmemory-mcp";};
    meta.mainProgram = "openmemory-mcp";
  }
