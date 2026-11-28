# Source floors select matching stable releases from the locked Go overlay.
{
  harness,
  inputs,
  lib,
  pkgs,
  ...
}: {
  checks.go-toolchain-floor = let
    inherit (harness) checkRows rejectsChange;
    vu = import ../../lib/toolchains.nix {inherit inputs;};
    # Multiple patches, an exact minor key and newer prereleases distinguish
    # exact lookup, minor fallback and stable-only selection for mkGoToolchain.
    versions =
      lib.genAttrs ["1.24" "1.24.1" "1.25.0" "1.25.9" "1.25.10" "1.25.11rc1" "1.26.0" "1.27rc1"]
      (version: {
        inherit version;
        outPath = "/fixture/go-${version}";
      });
    resolveFrom = releases: args:
      (import ../../lib/toolchains.nix {
        inputs.go-overlay.lib.mkGoBin = _: {versions = releases;};
      }).mkGoToolchain ({
          inherit pkgs;
          pname = "fixture";
        }
        // args);
    resolve = resolveFrom versions;
    rejectsSelection = valid: invalid: expected:
      rejectsChange (args: (resolve args).go.outPath) {inherit expected invalid valid;};
    rejects = invalid:
      rejectsSelection {floor = "1.25.0";} invalid "/fixture/go-1.25.0";
    rejectsOverride = override:
      rejectsSelection {override = "1.25.0";} {inherit override;} "/fixture/go-1.25.0";
    toolchain = resolve {floor = "1.25.0";};
    # The sentinel belongs to the upstream builder; replacing Go must retain it.
    builder = lib.makeOverridable ({
      go,
      sentinel,
    }: {inherit go sentinel;}) {
      go = throw "nixpkgs compiler must not be selected";
      sentinel = "upstream builder";
    };
    packageFor = name: lib.makeOverridable (args: args.${name}) {${name} = builder;};
    injected = name: toolchain.overridePackage (packageFor name);
    rejectsPackage = invalid:
      rejectsChange (args: let
        overridden = toolchain.overridePackage (lib.makeOverridable (builders: builders) args);
      in
        builtins.seq overridden (overridden.buildGoModule.go.outPath or null)) {
        inherit invalid;
        valid = {buildGoModule = builder;};
        expected = "/fixture/go-1.25.0";
      };
    latestFrom = releases: (resolveFrom releases {override = "latest";}).go.outPath;
    goBin = inputs.go-overlay.lib.mkGoBin pkgs;
    # Any exact key the locked overlay ships; go-overlay keeps past releases.
    lockedExact = "1.26.10";
    cases = {
      "bare minor selects newest stable patch of its minor" = (resolve {floor = "1.25";}).go.version == "1.25.10";
      "exact minor key precedes patch fallback" = (resolve {floor = "1.24";}).go.version == "1.24";
      "injects buildGo134Module compiler and retains defaults" =
        (injected "buildGo134Module").go.outPath
        == toolchain.go.outPath
        && (injected "buildGo134Module").sentinel == "upstream builder";
      "injects buildGoModule" = (injected "buildGoModule").go.outPath == toolchain.go.outPath;
      "latest override skips prereleases" = (resolve {override = "latest";}).go.version == "1.26.0";
      "locked exact release matches overlay derivation" =
        (vu.mkGoToolchain {
          floor = lockedExact;
          inherit pkgs;
          pname = "locked-fixture";
        }).go.outPath
        == goBin.versions.${lockedExact}.outPath;
      "missing floor allows latest override" =
        (resolve {
          floor = "0";
          override = "latest";
        }).go.version
        == "1.26.0";
      "override passthru records recipe choice" = (resolve {override = "latest";}).passthru.goToolchainOverride == "latest";
      "rejects a lock with no stable release" = rejectsChange latestFrom {
        valid = versions;
        invalid = {"1.27rc1" = versions."1.27rc1";};
        expected = "/fixture/go-1.26.0";
      };
      "rejects a package with no Go builder" = rejectsPackage {};
      "rejects a package with two Go builders" = rejectsPackage {
        buildGo134Module = builder;
        buildGoModule = builder;
      };
      "rejects a prerelease floor" = rejects {floor = "1.25.11rc1";};
      "rejects a prerelease override" = rejectsOverride "1.25.11rc1";
      "rejects a stale override" = rejects {
        floor = "1.25.0";
        override = "latest";
      };
      "rejects an empty floor" = rejects {floor = "";};
      "rejects an omitted floor" = rejects {};
      "rejects an override needing minor fallback" = rejectsOverride "1.25";
      "rejects an unavailable exact patch within a known minor" = rejects {floor = "1.25.1";};
      "rejects an unknown floor" = rejects {floor = "99.0.0";};
      "rejects an unknown override" = rejectsOverride "99.0.0";
      "rejects the missing-floor sentinel" = rejects {floor = "0";};
    };
  in
    assert checkRows "go-toolchain-floor" cases;
      pkgs.runCommand "go-toolchain-floor" {passthru = {inherit cases;};} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        echo 'source-matched locked Go: selection and builder contracts pass' > "$out"
      '';
}
