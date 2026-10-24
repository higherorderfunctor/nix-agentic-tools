{
  inputs,
  lib,
  pkgs,
  self,
  ...
}: let
  owner = ../.;
  packaging = import ../lib/packaging.nix {inherit inputs lib pkgs;};
  # Each installed suite is its own derivation so CI builds them in parallel;
  # run serially in one derivation they exceed the 60-minute matrix leg.
  installedSuite = name: tests: evidence:
    pkgs.runCommand name {
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
      python3 ${owner}/checks/run-domain-tests.py ${lib.concatMapStringsSep " " (test: "${owner}/checks/fixtures/${test}") tests}
      mkdir "$out"
      printf '%s passed\n' ${lib.escapeShellArg evidence} > "$out/evidence"
    '';
in {
  checks = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
    codeql-nix-all-definitions =
      installedSuite "codeql-nix-all-definitions" ["inc3/all-definitions/test_installed_all_definitions.py"]
      "M3d all-definitions with direct oracles";
    codeql-nix-graph =
      installedSuite "codeql-nix-graph" ["inc3/graph/test_graph.py"]
      "M3g module-graph installed qltest";
    codeql-nix-properties =
      installedSuite "codeql-nix-properties" ["inc3/properties/test_properties.py"]
      "M3p properties with real-Nix mutations";
    codeql-nix-renames =
      installedSuite "codeql-nix-renames" ["inc3/renames/test_renames.py"]
      "M3r renames with direct oracles";
    codeql-nix-step0 =
      installedSuite "codeql-nix-step0" ["step0/test_q0.py"]
      "Q0 installed queries, independent priority flip, equal retention, unselected throw and selected failure qltest";
  };
}
