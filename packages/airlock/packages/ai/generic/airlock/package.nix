# Airlock is built from the in-tree Rust workspace, so it has no upstream
# release for the update pipeline to track.
{
  pkgs,
  packageLib,
  ...
}: let
  inherit (pkgs) lib;
  rustPlatform = packageLib.mkRustPlatform {inherit pkgs;};
  root = ../../../..;
  cargoRoot = root + "/src";
  version = (lib.importTOML (cargoRoot + "/Cargo.toml")).workspace.package.version;
  src = lib.fileset.toSource {
    root = cargoRoot;
    fileset = lib.fileset.unions [
      (cargoRoot + "/Cargo.toml")
      (cargoRoot + "/Cargo.lock")
      (cargoRoot + "/crates")
    ];
  };
in
  rustPlatform.buildRustPackage {
    pname = "airlock";
    inherit src version;
    cargoLock.lockFile = cargoRoot + "/Cargo.lock";

    meta = {
      description = "Local egress proxy for coding harnesses";
      license = lib.licenses.unlicense;
      mainProgram = "airlock";
    };
    passthru.updateTargetExempt = "built from the in-repo workspace; no upstream release";
  }
