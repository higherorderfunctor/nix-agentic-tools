{
  inputs,
  lib,
  pkgs,
  self,
  ...
}: {
  checks = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
    codeql-nix-builtin-models = let
      owner = ../.;
      packaging = import ../lib/packaging.nix {inherit inputs lib pkgs;};
      treefmt = (inputs.treefmt-nix.lib.evalModule pkgs (import ../../../lib/treefmt-module.nix)).config;
    in
      pkgs.runCommand "codeql-nix-builtin-models" {
        CODEQL_NIX_TEST_BARE_COMMAND = "${self.ciPackages.${pkgs.stdenv.hostPlatform.system}.codeql-bare}/bin/codeql";
        CODEQL_NIX_TEST_BUILTIN_SOURCE = pkgs.nix.src;
        CODEQL_NIX_TEST_COMMAND = "${self.ciPackages.${pkgs.stdenv.hostPlatform.system}.codeql-nix}/bin/codeql";
        CODEQL_NIX_TEST_EXTRACTOR = packaging.extractor;
        CODEQL_NIX_TEST_FORMATTER = lib.getExe treefmt.package;
        CODEQL_NIX_TEST_FORMATTER_CONFIG = treefmt.build.configFile;
        CODEQL_NIX_TEST_LIBRARY = packaging.library;
        CODEQL_NIX_TEST_MODEL = "${packaging.library}/models/builtins.json";
        CODEQL_NIX_TEST_NIX = "${pkgs.nix}/bin/nix";
        CODEQL_NIX_TEST_NIXPKGS = pkgs.path;
        CODEQL_NIX_TEST_OWNER = owner;
        nativeBuildInputs = [pkgs.nix (pkgs.python3.withPackages (ps: [ps.jsonschema ps.tree-sitter ps.tree-sitter-grammars.tree-sitter-cpp])) pkgs.util-linux];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        export CODEQL_NIX_TEST_LOCK="$TMPDIR/codeql.lock"
        export CODEQL_NIX_TEST_SCRATCH="$TMPDIR"
        python3 ${owner}/checks/run-domain-tests.py ${owner}/checks/fixtures/builtin-models/test_models.py
        mkdir "$out"
        printf 'M3 runtime inventory, source metadata, aliases, exact compatibility, regeneration, fingerprints, named QL rows and independent Nix rename oracle passed\n' > "$out/evidence"
      '';
  };
}
