# Source floors select matching stable releases from the locked Go overlay.
{
  inputs,
  lib,
  pkgs,
  ...
}: {
  checks.go-toolchain-floor = let
    vu = import ../../lib/toolchains.nix {inherit inputs;};
    # Multiple patches, an exact minor key and newer prereleases distinguish
    # exact lookup, minor fallback and stable-only selection for mkGoToolchain.
    versions =
      lib.genAttrs ["1.24" "1.24.1" "1.25.0" "1.25.9" "1.25.10" "1.25.11rc1" "1.26.0" "1.27rc1"]
      (version: {
        inherit version;
        outPath = "/fixture/go-${version}";
      });
    fixture = import ../../lib/toolchains.nix {
      inputs.go-overlay.lib.mkGoBin = _: {inherit versions;};
    };
    resolve = args:
      fixture.mkGoToolchain ({
          inherit pkgs;
          pname = "fixture";
        }
        // args);
    probe = args: builtins.tryEval (resolve args).go.outPath;
    rejects = args: !(probe args).success;
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
    rejectsPackage = package: !(builtins.tryEval (builtins.deepSeq (toolchain.overridePackage package) true)).success;
    noStable =
      (import ../../lib/toolchains.nix {
        inputs.go-overlay.lib.mkGoBin = _: {versions = {"99.0rc1" = null;};};
      }).mkGoToolchain {
        override = "latest";
        inherit pkgs;
        pname = "no-stable";
      };
    recipeToolchain = resolve {
      floor = "1.25.0";
      recipeFile = "./package.nix";
    };
    goBin = inputs.go-overlay.lib.mkGoBin pkgs;
    releases = builtins.filter (v: builtins.match "[0-9]+\\.[0-9]+(\\.[0-9]+)?" v != null) (builtins.attrNames goBin.versions);
    latest = lib.last (builtins.sort lib.versionOlder releases);
    cases = {
      "bare minor selects newest stable patch of its minor" = (resolve {floor = "1.25";}).go.version == "1.25.10";
      "exact minor key precedes patch fallback" = (resolve {floor = "1.24";}).go.version == "1.24";
      "exact patch below newest does not simply grab newest" = toolchain.go.version == "1.25.0";
      "injects buildGo134Module compiler and retains defaults" =
        (injected "buildGo134Module").go.outPath
        == toolchain.go.outPath
        && (injected "buildGo134Module").sentinel == "upstream builder";
      "injects buildGoModule" = (injected "buildGoModule").go.outPath == toolchain.go.outPath;
      "latest override skips prereleases" = (resolve {override = "latest";}).go.version == "1.26.0";
      "locked exact release matches overlay derivation" =
        (vu.mkGoToolchain {
          floor = latest;
          inherit pkgs;
          pname = "locked-fixture";
        }).go.outPath
        == goBin.versions.${latest}.outPath;
      "missing floor allows exact override" = (resolve {override = "1.25.0";}).go.version == "1.25.0";
      "missing floor allows latest override" =
        (resolve {
          floor = "0";
          override = "latest";
        }).go.version
        == "1.26.0";
      "override passthru records recipe choice" = (resolve {override = "latest";}).passthru.goToolchainOverride == "latest";
      "recipe passthru carries floor and fixer" =
        recipeToolchain.passthru.goFloor
        == "1.25.0"
        && recipeToolchain.passthru.fixGoFloor.goFloorDestination == "recipe";
      "rejects a lock with no stable release" = !(builtins.tryEval noStable.go).success;
      "rejects a package with no Go builder" = rejectsPackage (lib.makeOverridable (args: args) {});
      "rejects a package with two Go builders" = rejectsPackage (lib.makeOverridable (args: args) {
        buildGo134Module = builder;
        buildGoModule = builder;
      });
      "rejects a prerelease floor" = rejects {floor = "1.25.11rc1";};
      "rejects a prerelease override" = rejects {override = "1.25.11rc1";};
      "rejects a stale override" = rejects {
        floor = "1.25.0";
        override = "latest";
      };
      "rejects an empty floor" = rejects {floor = "";};
      "rejects an omitted floor" = rejects {};
      "rejects an override needing minor fallback" = rejects {override = "1.25";};
      "rejects an unavailable exact patch within a known minor" = rejects {floor = "1.25.1";};
      "rejects an unknown floor" = rejects {floor = "99.0.0";};
      "rejects an unknown override" = rejects {override = "99.0.0";};
      "rejects the missing-floor sentinel" = rejects {floor = "0";};
      "tryEval positive control forces a resolvable compiler" =
        (probe {floor = "1.25.0";}).success
        && (probe {floor = "1.25.0";}).value == versions."1.25.0".outPath;
    };
    failing = builtins.attrNames (lib.filterAttrs (_: passed: !passed) cases);
  in
    assert lib.assertMsg (failing == []) "go-toolchain-floor: ${lib.concatStringsSep ", " failing}";
      pkgs.runCommand "go-toolchain-floor" {passthru = {inherit cases;};} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        echo 'source-matched locked Go: selection and builder contracts pass' > "$out"
      '';
}
