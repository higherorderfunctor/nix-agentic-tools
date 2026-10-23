{
  lib,
  pkgs,
  ...
}: {
  checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    codeql-nix-modules = let
      owner = ../.;
      python = pkgs.python3.withPackages (ps: [ps.jsonschema]);
    in
      pkgs.runCommand "codeql-nix-modules" {
        CODEQL_NIX_TEST_LIB = "${pkgs.path}/lib";
        CODEQL_NIX_TEST_NIX = "${pkgs.nix}/bin/nix";
        nativeBuildInputs = [pkgs.nix python];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        export HOME="$TMPDIR/home"
        mkdir "$HOME"
        python3 ${owner}/checks/run-domain-tests.py \
          ${owner}/checks/fixtures/step0/test_modules.py
        mkdir "$out"
        printf 'E2a module metadata, independent Nix oracles and transaction refusals passed\n' > "$out/evidence"
      '';
  };
}
