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
  goUpdate = vu.mkGoUpdateExtract {
    attr = pname;
    extraAfter = (extractedLib {inherit pkgs;}).regenCommand {name = pname;};
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
      src = fetchzip {inherit (sources.src) url hash;};
      vendorHash = sources.vendorHash or lib.fakeHash;
      passthru =
        (prev.passthru or {})
        // {
          inherit fixGoFloor fixVendorHash goFloor;
          extracted = import ../../../../extract {inherit pkgs;} package;
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
