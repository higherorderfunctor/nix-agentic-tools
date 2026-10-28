# Recorded rust-toolchain channels select only stable locked overlay releases.
{
  inputs,
  lib,
  pkgs,
  ...
}: {
  checks.rust-toolchain-selection = let
    vu = import ../../lib/toolchains.nix {inherit inputs;};
    versions = ["1.86.0" "1.86.9" "1.86.10" "1.86.11rc1" "1.99.1"];
    stable = lib.genAttrs versions (version: {
      default = lib.makeOverridable ({extensions ? []}: {
        inherit extensions version;
        outPath = "/fixture/rust-${version}";
      }) {};
    });
    fixture = import ../../lib/toolchains.nix {
      inputs.rust-overlay.lib.mkRustBin = _: _: {inherit stable;};
    };
    resolve = args:
      fixture.mkRustToolchain ({
          inherit pkgs;
          pname = "fixture";
        }
        // args);
    probe = args: builtins.tryEval (resolve args).outPath;
    rejects = args: !(probe args).success;
    locked = inputs.rust-overlay.lib.mkRustBin {} pkgs;
    cases = {
      "bare minor selects newest stable patch within its minor" = (resolve {channel = "1.86";}).version == "1.86.10";
      "exact patch below newest selects exact release" = (resolve {channel = "1.86.0";}).version == "1.86.0";
      "extensions reach the selected toolchain" =
        (resolve {
          channel = "1.86.0";
          extensions = ["rust-src"];
        }).extensions
        == ["rust-src"];
      "host-suffixed channel permits an exact recipe override" =
        (resolve {
          channel = "1.86.0-x86_64-unknown-linux-gnu";
          override = "1.86.0";
        }).version
        == "1.86.0";
      "latest override skips prereleases" = (resolve {override = "latest";}).version == "1.99.1";
      "locked exact release matches overlay derivation" =
        (vu.mkRustToolchain {
          inherit pkgs;
          pname = "locked-fixture";
          channel = "1.96.0";
        }).outPath
        == locked.stable."1.96.0".default.outPath;
      "missing channel permits exact override" = (resolve {override = "1.86.0";}).version == "1.86.0";
      "missing channel permits latest override" =
        (resolve {
          channel = "";
          override = "latest";
        }).version
        == "1.99.1";
      "nonnumeric beta permits an exact recipe override" =
        (resolve {
          channel = "beta";
          override = "1.86.0";
        }).version
        == "1.86.0";
      "nonnumeric nightly permits a latest recipe override" =
        (resolve {
          channel = "nightly-2026-10-27";
          override = "latest";
        }).version
        == "1.99.1";
      "nonnumeric stable permits a latest recipe override" =
        (resolve {
          channel = "stable";
          override = "latest";
        }).version
        == "1.99.1";
      "rejects a bare minor override" = rejects {override = "1.86";};
      "rejects a declared beta alias" = rejects {channel = "beta";};
      "rejects a declared dated nightly" = rejects {channel = "nightly-2026-10-27";};
      "rejects a declared stable alias" = rejects {channel = "stable";};
      "rejects a host-suffixed channel without a recipe override" = rejects {channel = "1.86.0-x86_64-unknown-linux-gnu";};
      "rejects a nonnumeric override" = rejects {override = "stable";};
      "rejects a prerelease" = rejects {channel = "1.86.11rc1";};
      "rejects a stale exact override" = rejects {
        channel = "1.86.0";
        override = "1.86.0";
      };
      "rejects a stale latest override" = rejects {
        channel = "1.86.0";
        override = "latest";
      };
      "rejects an empty channel" = rejects {channel = "";};
      "rejects an omitted channel" = rejects {};
      "rejects an unavailable patch of a known minor" = rejects {channel = "1.86.1";};
      "rejects an unknown channel" = rejects {channel = "99.0.0";};
      "rejects an unknown override" = rejects {override = "99.0.0";};
      "tryEval positive control forces a resolvable compiler" = (probe {channel = "1.86.0";}).success && (probe {channel = "1.86.0";}).value == stable."1.86.0".default.outPath;
    };
    failing = builtins.attrNames (lib.filterAttrs (_: passed: !passed) cases);
  in
    assert lib.assertMsg (failing == []) "rust-toolchain-selection: ${lib.concatStringsSep ", " failing}";
      pkgs.runCommand "rust-toolchain-selection" {passthru = {inherit cases;};} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        echo 'source-declared locked Rust: selection contracts pass' > "$out"
      '';
}
