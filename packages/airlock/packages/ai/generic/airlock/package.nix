# airlock: built from the in-repo cargo workspace at ../../../../src. The
# workspace version labels the build; there is no upstream release to sweep.
{
  packageLib,
  pkgs,
  ...
}: let
  inherit (pkgs) lib;
  rustPlatform = packageLib.mkRustPlatform {inherit pkgs;};
  root = ../../../../src;
in
  rustPlatform.buildRustPackage {
    pname = "airlock";
    inherit ((lib.importTOML (root + "/Cargo.toml")).workspace.package) version;
    # Only what cargo reads, so a local target/ or editor file never changes
    # the source hash.
    src = lib.fileset.toSource {
      inherit root;
      fileset = lib.fileset.unions [
        (root + "/Cargo.lock")
        (root + "/Cargo.toml")
        (root + "/crates")
      ];
    };
    cargoLock.lockFile = root + "/Cargo.lock";

    passthru.updateTargetExempt = "built from the in-repo workspace; its Cargo.toml version has no upstream release";

    meta = {
      description = "Credential-injecting egress gateway for coding harnesses";
      mainProgram = "airlock";
    };
  }
