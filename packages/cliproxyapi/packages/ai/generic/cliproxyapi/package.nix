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
      # settings checks (which copy `package.src`) all read the carried patches.
      src = pkgs.applyPatches {
        src = fetchzip {inherit (sources.src) url hash;};
        patches = [
          ../../../../patches/key-allowlist.patch
          ../../../../patches/zai-tool-shims.patch
        ];
        # A CPA release that changes the patched context fails here, loudly.
        patchFlags = ["-p1" "--fuzz=0"];
      };
      vendorHash = sources.vendorHash or lib.fakeHash;
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
