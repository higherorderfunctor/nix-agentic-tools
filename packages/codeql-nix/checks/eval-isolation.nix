{
  lib,
  pkgs,
  ...
}: {
  checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    codeql-nix-eval-isolation = let
      owner = ../.;
      python = pkgs.python3.withPackages (ps: [ps.jsonschema]);
    in
      pkgs.runCommand "codeql-nix-eval-isolation" {
        CODEQL_NIX_TEST_NIX = "${pkgs.nix}/bin/nix";
        nativeBuildInputs = [pkgs.nix python];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        export HOME="$TMPDIR/home"
        mkdir "$HOME"
        python3 ${owner}/checks/run-domain-tests.py \
          ${owner}/checks/fixtures/eval-isolation/test_supervisor.py
        mkdir "$out"
        printf 'E1 fake producer and real Nix isolation suites passed\n' > "$out/evidence"
      '';
  };
}
