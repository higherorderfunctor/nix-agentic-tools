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
          ${owner}/checks/fixtures/step0/test_modules.py \
          ${owner}/checks/fixtures/inc3/all-definitions/test_all_definitions.py \
          ${owner}/checks/fixtures/inc3/graph/test_graph_protocol.py \
          ${owner}/checks/fixtures/inc3/graph/test_graph_regressions.py \
          ${owner}/checks/fixtures/inc3/graph/test_graph_ownership.py \
          ${owner}/checks/fixtures/inc3/graph/test_facet_admission.py
        mkdir "$out"
        printf 'E2a module metadata, independent Nix oracles and transaction refusals passed\n' > "$out/evidence"
      '';
  };
}
