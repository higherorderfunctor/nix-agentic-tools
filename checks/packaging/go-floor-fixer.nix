# go-floor-fixer — exercise both mkGoFloorFix destinations and its exclusive
# destination contract with one synthetic pinned source.
{pkgs, ...}: {
  checks.go-floor-fixer = let
    vu = import ../../lib/packaging.nix;
    source = pkgs.writeTextDir "go.mod" ''
      module example.test/fixer

      go 1.26.8
    '';
    fakeNix = pkgs.writeShellScriptBin "nix" ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      printf '%s\n' ${source}
    '';
    helperPkgs = pkgs // {nix = fakeNix;};
    recipeFixer = vu.mkGoFloorFix {
      attr = "fixture";
      pkgs = helperPkgs;
      pname = "recipe-fixture";
      recipeFile = "./package.nix";
    };
    sidecarFixer = vu.mkGoFloorFix {
      attr = "fixture";
      pkgs = helperPkgs;
      pname = "sidecar-fixture";
      sourcesFile = "./sources.json";
    };
    missingDestination =
      builtins.tryEval
      (vu.mkGoFloorFix {
        attr = "fixture";
        pkgs = helperPkgs;
        pname = "missing-destination";
      }).drvPath;
    duplicateDestination =
      builtins.tryEval
      (vu.mkGoFloorFix {
        attr = "fixture";
        pkgs = helperPkgs;
        pname = "duplicate-destination";
        recipeFile = "./package.nix";
        sourcesFile = "./sources.json";
      }).drvPath;
  in
    assert recipeFixer.goFloorDestination == "recipe";
    assert sidecarFixer.goFloorDestination == "sidecar";
    assert !missingDestination.success;
    assert !duplicateDestination.success;
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
        test "$(jq -r .goFloor sources.json)" = 1.26.8
        test "$(jq -r .version sources.json)" = 1.0.0
        touch "$out"
      '';
}
