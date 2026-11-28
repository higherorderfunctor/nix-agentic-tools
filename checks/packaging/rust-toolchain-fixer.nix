# Exercise recipe and sidecar Rust channel writes from a nested crate root.
{
  harness,
  pkgs,
  ...
}: {
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
    inherit (harness) checkRows rejectsChange;
    mkFixer = overrides:
      vu.mkRustToolchainFix ({
          attr = "fixture";
          pkgs = helperPkgs;
          pname = "fixture";
          sourceRoot = "crate";
        }
        // overrides);
    recipe = {recipeFile = "./package.nix";};
    sidecar = {sourcesFile = "./sources.json";};
    recipeFixer = mkFixer recipe;
    sidecarFixer = mkFixer sidecar;
    destination = args: let
      fixer = mkFixer args;
    in
      builtins.seq fixer.drvPath fixer.rustToolchainDestination;
    rejectsDestination = invalid:
      rejectsChange destination {
        inherit invalid;
        valid = recipe;
        expected = "recipe";
      };
    cases = {
      "recipe destination reports its writer" = destination recipe == "recipe";
      "rejects both recipeFile and sourcesFile" = rejectsDestination (recipe // sidecar);
      "rejects omitted recipeFile and sourcesFile" = rejectsDestination {};
      "sidecar destination reports its writer" = destination sidecar == "sidecar";
    };
  in
    assert checkRows "rust-toolchain-fixer" cases;
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
