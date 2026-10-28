# Exercise recipe and sidecar Rust channel writes from a nested crate root.
{pkgs, ...}: {
  checks.rust-toolchain-fixer = let
    vu = import ../../lib/packaging.nix;
    source = pkgs.writeTextDir "crate/rust-toolchain.toml" ''
      [toolchain]
      channel = "1.88.0"
    '';
    fakeNix = pkgs.writeShellScriptBin "nix" ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      test "$*" = 'build --no-link --print-out-paths .#ciPackages.${pkgs.stdenv.hostPlatform.system}.fixture.src'
      printf '%s\n' ${source}
    '';
    helperPkgs = pkgs // {nix = fakeNix;};
    recipeFixer = vu.mkRustToolchainFix {
      attr = "fixture";
      pkgs = helperPkgs;
      pname = "recipe-fixture";
      recipeFile = "./package.nix";
      sourceRoot = "crate";
    };
    sidecarFixer = vu.mkRustToolchainFix {
      attr = "fixture";
      pkgs = helperPkgs;
      pname = "sidecar-fixture";
      sourceRoot = "crate";
      sourcesFile = "./sources.json";
    };
    missingDestination =
      builtins.tryEval
      (vu.mkRustToolchainFix {
        attr = "fixture";
        pkgs = helperPkgs;
        pname = "missing-destination";
      }).drvPath;
    duplicateDestination =
      builtins.tryEval
      (vu.mkRustToolchainFix {
        attr = "fixture";
        pkgs = helperPkgs;
        pname = "duplicate-destination";
        recipeFile = "./package.nix";
        sourcesFile = "./sources.json";
      }).drvPath;
    cases = {
      "recipe destination reports its writer" = recipeFixer.rustToolchainDestination == "recipe";
      "recipe destination tryEval forces a valid derivation" = (builtins.tryEval recipeFixer.drvPath).success;
      "rejects both recipeFile and sourcesFile" = !duplicateDestination.success;
      "rejects omitted recipeFile and sourcesFile" = !missingDestination.success;
      "sidecar destination reports its writer" = sidecarFixer.rustToolchainDestination == "sidecar";
      "sidecar destination tryEval forces a valid derivation" = (builtins.tryEval sidecarFixer.drvPath).success;
    };
  in
    assert pkgs.lib.all (passed: passed) (builtins.attrValues cases);
      pkgs.runCommand "rust-toolchain-fixer-check" {
        nativeBuildInputs = [pkgs.jq];
        passthru = {inherit cases;};
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :

        cat >package.nix <<'EOF'
        {
          rustToolchainChannel = "1.86.0";
          version = "1.0.0";
        }
        EOF
        printf '%s\n' '{"rustToolchainChannel":"1.87.0","version":"1.0.0"}' >sources.json

        cp sources.json sources.before
        ${recipeFixer}
        grep -Fx '  rustToolchainChannel = "1.88.0";' package.nix
        grep -Fx '  version = "1.0.0";' package.nix
        cmp sources.before sources.json

        cp package.nix package.before
        ${sidecarFixer}
        test "$(jq -r .rustToolchainChannel sources.json)" = 1.88.0
        test "$(jq -r .version sources.json)" = 1.0.0
        cmp package.before package.nix
        test ! -e package.nix.new
        test ! -e sources.json.new
        touch "$out"
      '';
}
