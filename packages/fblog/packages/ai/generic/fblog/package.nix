# fblog: nixpkgs build recipe with release source and Cargo vendor pins.
# The release updater records the source channel before Cargo vendor hashes.
{
  pkgs,
  packageLib,
  repoPath,
  ...
}: let
  inherit (pkgs) lib;
  sources = builtins.fromJSON (builtins.readFile ../../../../sources.json);
  sourcesFile = repoPath ../../../../sources.json;
  inherit (sources) version;
  rustPlatform = packageLib.mkRustPlatform {
    inherit pkgs sources sourcesFile;
    override = "latest";
    pname = "fblog";
  };
  src = pkgs.fetchFromGitHub {
    owner = "brocode";
    repo = "fblog";
    tag = "v${version}";
    hash = sources.srcHash or lib.fakeHash;
  };
in
  (pkgs.fblog.override {inherit rustPlatform;}).overrideAttrs (finalAttrs: _: {
    inherit src version;
    passthru =
      rustPlatform.passthru
      // {
        updateScript = packageLib.mkUpdateScript {
          extraExtract = "${rustPlatform.passthru.rustUpdateExtract}";
          inherit pkgs sourcesFile;
          platforms = {};
          pname = "fblog";
          versionCheck.cmd = packageLib.ghLatestVersionCmd {
            inherit pkgs;
            repo = "brocode/fblog";
          };
        };
      };
    cargoDeps = rustPlatform.fetchCargoVendor {
      # pname and version name the output, so a stale hash cannot reuse the
      # previous release's cached vendor set after a bump.
      inherit (finalAttrs) pname version src;
      hash = sources.cargoHash or lib.fakeHash;
    };
  })
