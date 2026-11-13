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
      src = (packageLib.patching {inherit pkgs;}).source {
        src = fetchzip {inherit (sources.src) url hash;};
        patchFiles = [
          ../../../../patches/key-allowlist.patch
          ../../../../patches/zai-tool-shims.patch
          ../../../../patches/passthrough-provider.patch
        ];
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
