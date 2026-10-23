{
  inputs,
  lib,
  pkgs,
  self,
  ...
}: {
  checks = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
    codeql-nix-installed = let
      owner = ../.;
      packaging = import ../lib/packaging.nix {inherit inputs lib pkgs;};
    in
      pkgs.runCommand "codeql-nix-installed" {
        CODEQL_NIX_TEST_BARE_COMMAND = "${self.ciPackages.${pkgs.stdenv.hostPlatform.system}.codeql-bare}/bin/codeql";
        CODEQL_NIX_TEST_COMMAND = "${self.ciPackages.${pkgs.stdenv.hostPlatform.system}.codeql-nix}/bin/codeql";
        CODEQL_NIX_TEST_EXTRACTOR = packaging.extractor;
        CODEQL_NIX_TEST_LIBRARY = packaging.library;
        CODEQL_NIX_TEST_NIX = "${pkgs.nix}/bin/nix";
        CODEQL_NIX_TEST_NIXPKGS = pkgs.path;
        CODEQL_NIX_TEST_OWNER = owner;
        nativeBuildInputs = [pkgs.nix (pkgs.python3.withPackages (ps: [ps.jsonschema])) pkgs.util-linux];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        export CODEQL_NIX_TEST_LOCK="$TMPDIR/codeql.lock"
        export CODEQL_NIX_TEST_SCRATCH="$TMPDIR"
        python3 ${owner}/checks/run-domain-tests.py \
          ${owner}/checks/fixtures/installed/test_installed.py \
          ${owner}/checks/fixtures/installed/test_r0.py \
          ${owner}/checks/fixtures/installed/test_review_regressions.py
        mkdir "$out"
        printf 'P2a installed offline resolution, identical schemas, syntax and module metadata database, oracle override, target discovery and input-pin refusals passed\n' > "$out/evidence"
      '';
  };
}
