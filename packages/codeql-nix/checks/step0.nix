{
  lib,
  pkgs,
  self,
  ...
}: {
  checks = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
    codeql-nix-step0 = let
      owner = ../.;
      packaging = import ../lib/packaging.nix {inherit lib pkgs;};
    in
      pkgs.runCommand "codeql-nix-step0" {
        CODEQL_NIX_TEST_COMMAND = "${self.ciPackages.${pkgs.stdenv.hostPlatform.system}.codeql-nix}/bin/codeql";
        CODEQL_NIX_TEST_EXTRACTOR = packaging.extractor;
        CODEQL_NIX_TEST_LIBRARY = packaging.library;
        CODEQL_NIX_TEST_NIX = "${pkgs.nix}/bin/nix";
        CODEQL_NIX_TEST_NIXPKGS = pkgs.path;
        CODEQL_NIX_TEST_OWNER = owner;
        CODEQL_NIX_TEST_QUERIES = packaging.queries;
        nativeBuildInputs = [pkgs.nix (pkgs.python3.withPackages (ps: [ps.jsonschema])) pkgs.util-linux];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        export CODEQL_NIX_TEST_LOCK="$TMPDIR/codeql.lock"
        export CODEQL_NIX_TEST_SCRATCH="$TMPDIR"
        python3 ${owner}/checks/run-domain-tests.py ${owner}/checks/fixtures/step0/test_q0.py
        mkdir "$out"
        printf 'Q0 installed queries, independent priority flip, equal retention, unselected throw, selected failure and qltest passed\n' > "$out/evidence"
      '';
  };
}
