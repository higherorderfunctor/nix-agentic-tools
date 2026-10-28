# Airlock is built from the in-tree Rust workspace, so it has no upstream
# release for the update pipeline to track.
{
  pkgs,
  packageLib,
  ...
}: let
  inherit (pkgs) lib;
  rustToolchainChannel = "";
  rustPlatform = packageLib.mkRustPlatform {
    channel = rustToolchainChannel;
    inherit pkgs;
    override = "latest";
    pname = "airlock";
  };
  cargoRoot = ../../..;
  version = (lib.importTOML (cargoRoot + "/Cargo.toml")).workspace.package.version;
  src = lib.fileset.toSource {
    root = cargoRoot;
    fileset = lib.fileset.unions [
      (cargoRoot + "/Cargo.lock")
      (cargoRoot + "/Cargo.toml")
      (lib.fileset.maybeMissing (cargoRoot + "/rust-toolchain"))
      (lib.fileset.maybeMissing (cargoRoot + "/rust-toolchain.toml"))
      ./Cargo.toml
      ./src
      ./tests
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
    passthru =
      rustPlatform.passthru
      // {
        updateTargetExempt = "built from the in-repo workspace; no upstream release";
      };
  }
