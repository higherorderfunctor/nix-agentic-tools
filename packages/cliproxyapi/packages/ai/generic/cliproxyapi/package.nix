{
  extractedLib,
  packageLib,
  pkgs,
  repoPath,
  ...
}: let
  inherit (pkgs) fetchzip lib;
  vu = packageLib;
  pname = "cliproxyapi";
  sources = builtins.fromJSON (builtins.readFile ../../../../sources.json);
  sourcesFile = repoPath ../../../../sources.json;
  extraction = extractedLib {inherit pkgs;};
  goUpdate = vu.mkGoUpdateExtract {
    attr = pname;
    extraAfter = extraction.regenCommand {name = pname;};
    inherit pkgs pname sourcesFile;
  };
  inherit (goUpdate) fixGoFloor fixVendorHash;
  goFloor = sources.goFloor or vu.goFloorUnknown;
  package =
    ((vu.mkGoToolchain {
        floor = goFloor;
        inherit pkgs pname;
      }).overridePackage
      pkgs.cliproxyapi)
  .overrideAttrs (prev: {
      inherit (sources) version;
      # The patched tree is `src` itself, so the build, the extractor and the
      # settings checks (which copy `package.src`) all read the allowlist.
      src = pkgs.applyPatches {
        src = fetchzip {inherit (sources.src) url hash;};
        patches = [../../../../patches/key-allowlist.patch];
        # A CPA release that changes the patched context fails here, loudly.
        patchFlags = ["-p1" "--fuzz=0"];
      };
      vendorHash = sources.vendorHash or lib.fakeHash;
      # subPackages builds cmd/server; its default check never reaches executors.
      doCheck = true;
      preCheck =
        (prev.preCheck or "")
        + ''
          cp ${../../../../checks/gate_bump_test.go} internal/config/nat_gate_bump_test.go
          cp ${../../../../checks/fixtures/gate-bump-golden.json} internal/config/nat_gate_golden.json
          cp ${../../../../checks/exact_models_test.go} internal/runtime/executor/nat_exact_models_test.go
          cp ${pkgs.writeText "nat-exact-config.json" (builtins.toJSON ((import ../../../../lib/exact-models.nix {inherit lib;}).settings // {config-version = 8;}))} internal/runtime/executor/nat_exact_config.json
        '';
      checkPhase = ''
        (
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          runHook preCheck
          go test -v -count=1 -run '^TestNatGateBump' ./internal/config
          go test -v -count=1 -run '^TestNatExact' ./internal/runtime/executor
          runHook postCheck
        )
      '';
      passthru =
        (prev.passthru or {})
        // {
          inherit fixGoFloor fixVendorHash goFloor;
          extracted = extraction.goTestExtract {
            inherit package;
            packagePath = "internal/config";
            testFile = ../../../../extract/config_test.go;
          };
          goUpdateExtract = goUpdate.extract;
          updateScript = vu.ghArchiveUpdateScript {
            extraExtract = "${goUpdate.extract}";
            inherit pkgs pname sourcesFile;
            repo = "router-for-me/CLIProxyAPI";
          };
        };
    });
in
  package
