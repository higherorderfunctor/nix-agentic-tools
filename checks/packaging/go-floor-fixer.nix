# go-floor-fixer — exercise both mkGoFloorFix destinations and its exclusive
# destination contract with one synthetic pinned source.
{
  harness,
  pkgs,
  ...
}: {
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
    inherit (harness) checkRows rejectsChange;
    mkFixer = overrides:
      vu.mkGoFloorFix ({
          attr = "fixture";
          pkgs = helperPkgs;
          pname = "fixture";
        }
        // overrides);
    recipe = {recipeFile = "./package.nix";};
    sidecar = {sourcesFile = "./sources.json";};
    recipeFixer = mkFixer recipe;
    sidecarFixer = mkFixer sidecar;
    destination = args: let
      fixer = mkFixer args;
    in
      builtins.seq fixer.drvPath fixer.goFloorDestination;
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
    assert checkRows "go-floor-fixer" cases;
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
