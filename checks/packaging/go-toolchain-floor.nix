# The locked overlay's newest stable compiler is used regardless of nixpkgs Go.
{
  inputs,
  lib,
  pkgs,
  ...
}: {
  checks.go-toolchain-floor = let
    vu = import ../../lib/toolchains.nix {inherit inputs;};
    goBin = inputs.go-overlay.lib.mkGoBin pkgs;
    resolve = floor:
      vu.mkGoToolchain {
        inherit floor;
        inherit pkgs;
        pname = "fixture";
      };
    releases =
      builtins.filter (v: builtins.match "[0-9]+\\.[0-9]+(\\.[0-9]+)?" v != null)
      (builtins.attrNames goBin.versions);
    latest = lib.last (builtins.sort lib.versionOlder releases);
    expected = goBin.versions.${latest};
    toolchain = resolve "0";
    # The sentinel proves a versioned builder's defaults survive replacement.
    builder = lib.makeOverridable ({
      go,
      sentinel,
    }: {inherit go sentinel;}) {
      go = throw "nixpkgs compiler must not be selected";
      sentinel = "upstream builder";
    };
    packageFor = name: lib.makeOverridable (args: args.${name}) {${name} = builder;};
    injected = name: toolchain.overridePackage (packageFor name);
    rejects = package: !(builtins.tryEval (builtins.deepSeq (toolchain.overridePackage package) true)).success;
    noStable =
      (import ../../lib/toolchains.nix {
        inputs.go-overlay.lib.mkGoBin = _: {versions = {"99.0rc1" = null;};};
      }).mkGoToolchain {
        floor = "0";
        inherit pkgs;
        pname = "no-stable";
      };
    recipeToolchain = vu.mkGoToolchain {
      floor = "1.17";
      inherit pkgs;
      pname = "fixture";
      recipeFile = "./package.nix";
    };
    cases = {
      "accepts the newest locked stable Go" = (resolve latest).go.outPath == expected.outPath;
      "accepts the vacuous floor" = toolchain.go.outPath == expected.outPath;
      "accepts a lower floor" = (resolve "1.17").go.outPath == expected.outPath;
      "fixture holds a non-stable release" = lib.any (v: !(lib.elem v releases)) (builtins.attrNames goBin.versions);
      "injects buildGo127Module" = (injected "buildGo127Module").go.outPath == expected.outPath;
      "injects buildGoModule" = (injected "buildGoModule").go.outPath == expected.outPath;
      "keeps versioned builder defaults" = (injected "buildGo134Module").sentinel == "upstream builder";
      "omits floor passthru without a recipe" = toolchain.passthru == {};
      "recipe passthru carries floor and fixer" =
        recipeToolchain.passthru.goFloor
        == "1.17"
        && recipeToolchain.passthru.fixGoFloor.goFloorDestination == "recipe";
      "rejects a floor above the locked Go" = !(builtins.tryEval (resolve "99.0.0").go).success;
      "rejects a lock with no stable release" = !(builtins.tryEval noStable.go).success;
      "rejects a package with no Go builder" = rejects (lib.makeOverridable (args: args) {});
      "rejects a package with two Go builders" = rejects (lib.makeOverridable (args: args) {
        buildGoModule = builder;
        buildGo127Module = builder;
      });
    };
    failing = builtins.attrNames (lib.filterAttrs (_: passed: !passed) cases);
  in
    assert lib.assertMsg (failing == []) "go-toolchain-floor: ${lib.concatStringsSep ", " failing}";
      pkgs.runCommand "go-toolchain-floor" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        echo 'locked stable Go ${latest}: selection and builder contracts pass' > "$out"
      '';
}
