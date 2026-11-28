# go-floor-fixer — exercise both mkGoFloorFix destinations with different
# floors so the recipe must read the default path and the sidecar the override.
{pkgs, ...}: {
  checks.go-floor-fixer = let
    vu = import ../../lib/packaging.nix;
    goMod = path: floor:
      pkgs.writeTextDir path ''
        module example.test/fixer

        go ${floor}
      '';
    source = pkgs.symlinkJoin {
      name = "go-floor-fixer-source";
      paths = [(goMod "go.mod" "1.26.8") (goMod "src/go.mod" "1.26.9")];
    };
    fakeNix = pkgs.writeShellScriptBin "nix" ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      printf '%s\n' ${source}
    '';
    helperPkgs = pkgs // {nix = fakeNix;};
    mkFixer = overrides:
      vu.mkGoFloorFix ({
          attr = "fixture";
          pkgs = helperPkgs;
          pname = "fixture";
        }
        // overrides);
    recipe = {recipeFile = "./package.nix";};
    sidecar = {
      goModPath = "src/go.mod";
      sourcesFile = "./sources.json";
    };
    recipeFixer = mkFixer recipe;
    sidecarFixer = mkFixer sidecar;
  in
    pkgs.runCommand "go-floor-fixer-check" {
      nativeBuildInputs = [pkgs.jq];
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      cat >package.nix <<'EOF'
      {
        goFloor = "1.25.12";
      }
      EOF
      printf '%s\n' '{"goFloor":"1.25.12","version":"1.0.0"}' >sources.json

      ${recipeFixer}
      ${sidecarFixer}

      grep -Fx '  goFloor = "1.26.8";' package.nix
      test "$(jq -r .goFloor sources.json)" = 1.26.9
      touch "$out"
    '';
}
