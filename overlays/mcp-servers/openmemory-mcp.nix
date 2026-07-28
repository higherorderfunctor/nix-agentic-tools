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

  rev = "9fdfc2ac09317881d0cdad6efd8b4859fc886323";
  src = fetchFromGitHub {
    owner = "CaviraOSS";
    repo = "OpenMemory";
    inherit rev;
    hash = "sha256-pVHStYuECa+X4XRk7fNJOWHv+ij2ZikdbDj+xK2XBXY=";
  };

  # The auto-memory backend helper (STAGE 5, D19/D20): a thin CLI over the
  # in-process `Memory` SDK. Shipped FROM this package (not a separate overlay)
  # so it shares the exact `dist/` + `node_modules` the daemon runs — guaranteeing
  # SDK/Postgres-schema lockstep. Source is repo-local (consumer-stable → cache-hit
  # parity holds). Referenced as individual file paths so only the helper (not its
  # test) enters $out. See docs/plans/kiro-cli-auto-memory.md.
  memHelper = ../../packages/openmemory-mcp/mem/openmemory-mem.ts;
  memTest = ../../packages/openmemory-mcp/mem/openmemory-mem.test.ts;
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

    # Run the openmemory-mem helper's own bun suite in-sandbox (pure: stub
    # backend, no Postgres/dist load), so a real regression fails the build.
    # Copied into an isolated temp dir so bun does not pick up the upstream
    # vitest suite in sourceRoot.
    doCheck = true;
    nativeCheckInputs = [bun];
    checkPhase = ''
      runHook preCheck
      mem_test_dir="$(mktemp -d)"
      cp ${memHelper} "$mem_test_dir/openmemory-mem.ts"
      cp ${memTest} "$mem_test_dir/openmemory-mem.test.ts"
      HOME="$TMPDIR" ${bun}/bin/bun test "$mem_test_dir/openmemory-mem.test.ts"
      runHook postCheck
    '';

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
      # Auto-memory backend helper (STAGE 5): resolves `./dist/index.js` relative
      # to itself, so its openmemory-js deps load from the sibling node_modules.
      cp ${memHelper} $out/lib/openmemory-mcp/openmemory-mem.ts
      makeWrapper ${bun}/bin/bun $out/bin/openmemory-mem \
        --add-flags "$out/lib/openmemory-mcp/openmemory-mem.ts"
      runHook postInstall
    '';
    doInstallCheck = true;
    installCheckPhase = vu.mkMcpSmokeTest {bin = "openmemory-mcp";};
    # openmemory-mem smoke (runs via mkMcpSmokeTest's `runHook postInstallCheck`):
    # empty stdin short-circuits before any dist/Postgres load, proving bun resolves
    # the wrapped entry + dispatch runs. Live PG is exercised at the consumer flip.
    postInstallCheck = ''
      echo -n "" | $out/bin/openmemory-mem add --project-id smoke
      echo -n "" | $out/bin/openmemory-mem query --project-id smoke
    '';
    meta.mainProgram = "openmemory-mcp";
  }
