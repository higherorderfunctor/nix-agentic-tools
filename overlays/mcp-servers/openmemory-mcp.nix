# openmemory-mcp — builds from CaviraOSS/OpenMemory mono-repo.
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) buildNpmPackage fetchFromGitHub makeWrapper nodejs;

  src = fetchFromGitHub {
    owner = "CaviraOSS";
    repo = "OpenMemory";
    rev = "a65c920636b1b39618e833f1a0f8494aebccafcd";
    hash = "sha256-cXbftztatmbYPv4uYh3YVpXS65yHzs+D6EOR5Y7x9rw=";
  };
in
  buildNpmPackage {
    pname = "openmemory-mcp";
    version = "unstable-2026-04-08";
    inherit src;
    sourceRoot = "source/packages/openmemory-js";
    postPatch = "cp ${../sources/locks/openmemory-mcp-package-lock.json} package-lock.json";
    npmDepsHash = "sha256-1V0U86HsQL+auSVrlEPF9GAnE2LYSb78tfcoTmCitOU=";
    # Source needs building (tsc). npm tarball had pre-built dist/.
    nativeBuildInputs = [makeWrapper];
    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/openmemory-mcp $out/bin
      cp -r bin dist node_modules package.json $out/lib/openmemory-mcp/
      makeWrapper ${nodejs}/bin/node $out/bin/openmemory-mcp \
        --add-flags "$out/lib/openmemory-mcp/bin/opm.js" \
        --add-flags "mcp"
      makeWrapper ${nodejs}/bin/node $out/bin/openmemory-mcp-serve \
        --add-flags "$out/lib/openmemory-mcp/bin/opm.js" \
        --add-flags "serve"
      runHook postInstall
    '';
    meta.mainProgram = "openmemory-mcp";
  }
