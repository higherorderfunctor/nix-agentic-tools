# Recorded rust-toolchain channels select only stable locked overlay releases.
{
  harness,
  inputs,
  lib,
  pkgs,
  ...
}: {
  checks.rust-toolchain-selection = let
    inherit (harness) checkRows rejectsChange;
    vu = import ../../lib/toolchains.nix {inherit inputs;};
    # Each prerelease would win its respective sort if not filtered: one
    # outranks the stable patch in 1.86, and one outranks all stable releases.
    versions = ["1.86.0" "1.86.9" "1.86.10" "1.86.11rc1" "1.99.1" "1.100.0rc1"];
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
    rejectsSelection = valid: invalid: expected:
      rejectsChange (args: (resolve args).outPath) {inherit expected invalid valid;};
    rejects = invalid:
      rejectsSelection {channel = "1.86.0";} invalid "/fixture/rust-1.86.0";
    rejectsOverride = override:
      rejectsSelection {override = "1.86.0";} {inherit override;} "/fixture/rust-1.86.0";
    hostedExact = "1.86.0-x86_64-unknown-linux-gnu";
    hostedMinor = "1.86-x86_64-unknown-linux-gnu";
    rejectsStaleOverride = channel: override: expected:
      rejectsSelection {inherit channel;} {inherit channel override;} expected;
    platform = args:
      fixture.mkRustPlatform ({
          inherit pkgs;
          channel = hostedExact;
          pname = "fixture";
        }
        // args);
    recipe = {recipeFile = "./package.nix";};
    platformChannel = args: (platform args).passthru.rustToolchainChannel;
    rejectsDestination = invalid:
      rejectsChange platformChannel {
        inherit invalid;
        valid = recipe;
        expected = "1.86.0-x86_64-unknown-linux-gnu";
      };
    locked = inputs.rust-overlay.lib.mkRustBin {} pkgs;
    cases = {
      "bare minor selects 1.86.10 rather than an older patch, prerelease or newer minor" = (resolve {channel = "1.86";}).version == "1.86.10";
      "exact patch below newest selects exact release" = (resolve {channel = "1.86.0";}).version == "1.86.0";
      "extensions reach the selected toolchain" =
        (resolve {
          channel = "1.86.0";
          extensions = ["rust-src"];
        }).extensions
        == ["rust-src"];
      "host-suffixed exact channel selects its release" = (resolve {channel = hostedExact;}).version == "1.86.0";
      "latest override selects 1.99.1 rather than the newer 1.100.0 prerelease" = (resolve {override = "latest";}).version == "1.99.1";
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
      "mkRustPlatform preserves host-suffixed channel for drift" = platformChannel recipe == "1.86.0-x86_64-unknown-linux-gnu";
      "nonnumeric source channel permits an exact override" =
        (resolve {
          channel = "nightly";
          override = "1.86.0";
        }).outPath
        == "/fixture/rust-1.86.0";
      "rejects a bare minor override" = rejectsOverride "1.86";
      "rejects a dated numeric channel as no host" = rejects {channel = "1.86-2026-10-27";};
      "rejects a declared beta alias" = rejects {channel = "beta";};
      "rejects a declared dated beta" = rejects {channel = "beta-2026-10-27";};
      "rejects a declared dated nightly" = rejects {channel = "nightly-2026-10-27";};
      "rejects a declared nightly alias" = rejects {channel = "nightly";};
      "rejects a declared stable alias" = rejects {channel = "stable";};
      "rejects a nonnumeric override" = rejectsOverride "stable";
      "rejects a prerelease" = rejects {channel = "1.86.11rc1";};
      "rejects a stale exact override" = rejectsStaleOverride "1.86.0" "1.86.0" "/fixture/rust-1.86.0";
      "rejects a stale host-suffixed exact override" = rejectsStaleOverride hostedExact "1.86.0" "/fixture/rust-1.86.0";
      "rejects a stale host-suffixed latest override" = rejectsStaleOverride hostedExact "latest" "/fixture/rust-1.86.0";
      "rejects a stale host-suffixed minor override" = rejectsStaleOverride hostedMinor "1.86.0" "/fixture/rust-1.86.10";
      "rejects a stale latest override" = rejectsStaleOverride "1.86.0" "latest" "/fixture/rust-1.86.0";
      "rejects an empty channel" = rejects {channel = "";};
      "rejects an omitted channel" = rejects {};
      "rejects an unavailable patch of a known minor" = rejects {channel = "1.86.1";};
      "rejects an unknown channel" = rejects {channel = "99.0.0";};
      "rejects an unknown override" = rejectsOverride "99.0.0";
      "rejects mkRustPlatform with both recipeFile and sourcesFile" = rejectsDestination (recipe // {sourcesFile = "./sources.json";});
      "rejects mkRustPlatform without recipeFile or sourcesFile" = rejectsDestination {};
    };
  in
    assert checkRows "rust-toolchain-selection" cases;
      pkgs.runCommand "rust-toolchain-selection" {passthru = {inherit cases;};} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        echo 'source-declared locked Rust: selection contracts pass' > "$out"
      '';
}
