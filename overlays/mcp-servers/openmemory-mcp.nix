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

  rev = "9d1f44a24ab2969ed87f8f88746729ffff0a539c";
  src = fetchFromGitHub {
    owner = "CaviraOSS";
    repo = "OpenMemory";
    inherit rev;
    hash = "sha256-M4CltkPq4K7Htj5QeKCnIAOF3zUCedQQaneyNzyBhcw=";
  };
in
  buildNpmPackage {
    pname = "openmemory-mcp";
    version = vu.mkVersion {
      upstream = vu.readPackageJsonVersion "${src}/packages/openmemory-js/package.json";
      inherit rev;
    };
    inherit src;
    sourceRoot = "source/packages/openmemory-js";
    postUnpack = "chmod -R u+w source";
    npmDepsHash = "sha256-ZL+/UtzRohRVU4OeSSSHm7A6Dxut22LQ5VGfPOaNsm8=";
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
