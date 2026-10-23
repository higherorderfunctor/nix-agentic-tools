{
  inputs,
  lib,
  pkgs,
  self,
  ...
}: {
  checks = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
    codeql-nix-anchors = let
      build = strictShell {
        name = "qltest.sh";
        text = ''
          exec "$CODEQL_DIST/codeql" database index-files \
            --language=nix --include-extension=.nix --working-dir=. \
            "$CODEQL_EXTRACTOR_NIX_WIP_DATABASE"
        '';
      };
      engine = self.ciPackages.${pkgs.stdenv.hostPlatform.system}.codeql-bare;
      index = strictShell {
        name = "index-files.sh";
        text = ''
          exec ${pkgs.python3}/bin/python3 ${./fixtures/anchors/extract_fixture.py} \
            "$1" ${packaging.syntaxDriver}/bin/nixql-syntax
        '';
      };
      installed = pkgs.runCommand "nixql-anchors-extractor" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        mkdir -p "$out/tools"
        cp ${packaging.generated}/nix.dbscheme "$out/nix.dbscheme"
        printf '<dbstats><typesizes/><stats/></dbstats>\n' > "$out/nix.dbscheme.stats"
        cat > "$out/codeql-extractor.yml" <<'MANIFEST'
        build_modes: [none]
        column_kind: utf8
        display_name: Nix anchor fixture
        file_types:
          - extensions: [.nix]
            name: nix
        legacy_qltest_extraction: true
        name: nix
        version: 0.0.0
        MANIFEST
        ln -s ${index}/bin/index-files.sh "$out/tools/index-files.sh"
        ln -s ${build}/bin/qltest.sh "$out/tools/qltest.sh"
        ln -s ${build}/bin/qltest.sh "$out/tools/autobuild.sh"
      '';
      owner = ../.;
      packaging = import ../lib/packaging.nix {inherit inputs lib pkgs;};
      strictShell = import ../../../lib/strict-shell-application.nix pkgs;
    in
      pkgs.runCommand "codeql-nix-anchors" {
        nativeBuildInputs = [engine pkgs.nix pkgs.python3 pkgs.util-linux];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        export NIXQL_SYNTAX_DRIVER=${packaging.syntaxDriver}/bin/nixql-syntax
        python3 ${owner}/checks/run-domain-tests.py \
          ${owner}/checks/fixtures/anchors/test_driver.py
        python3 - ${owner}/checks/fixtures/bootstrap/test-preflight.py \
          ${packaging.syntaxFixture}/bin/bootstrap-probe "$TMPDIR/preflight" <<'PY'
        import importlib.util
        from pathlib import Path
        import sys

        spec = importlib.util.spec_from_file_location("preflight", sys.argv[1])
        preflight = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(preflight)
        scratch = Path(sys.argv[3])
        scratch.mkdir()
        preflight.syntax_cases(Path(sys.argv[2]), scratch)
        PY
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME" tests/ambiguous
        cp ${owner}/ql/test/qlpack.yml tests/
        cp -r ${owner}/ql/test/anchors tests/
        chmod -R u+w tests
        for template in tests/anchors/*.nix.in; do
          cp "$template" "''${template%.in}"
        done
        flock "$TMPDIR/codeql.lock" codeql test run \
          --search-path=${installed}:${packaging.library} \
          --threads=4 --ram=6000 --keep-databases tests/anchors
        python3 ${owner}/checks/fixtures/raw-inventory/validate_archive.py \
          tests/anchors/anchors.testproj/src tests/anchors \
          tests/anchors/Coordinates.expected tests/anchors/Empty.expected \
          tests/anchors/Features.expected tests/anchors/Quality.expected
        cp tests/anchors/bridge.nix tests/ambiguous/
        cp tests/anchors/Quality.ql tests/ambiguous/Ambiguous.ql
        cp tests/anchors/Ambiguous.expected tests/ambiguous/
        NIXQL_TEST_DUPLICATE_RAW=1 flock "$TMPDIR/codeql.lock" codeql test run \
          --search-path=${installed}:${packaging.library} \
          --threads=4 --ram=6000 tests/ambiguous
        mkdir tests/step0
        cp ${owner}/ql/test/step0/{Ast,Candidates}.{ql,expected} \
          ${owner}/ql/test/step0/{Ambiguous.expected,*.nix.in} tests/step0/
        chmod -R u+w tests/step0
        for template in tests/step0/*.nix.in; do
          cp "$template" "''${template%.in}"
        done
        flock "$TMPDIR/codeql.lock" codeql test run \
          --search-path=${installed}:${packaging.library} \
          --threads=4 --ram=6000 tests/step0
        python3 ${owner}/checks/fixtures/step0/reconstruct.py \
          tests/step0/Ast.expected tests/step0/forms.nix
        mkdir tests/ast-ambiguous
        cp tests/step0/*.nix tests/ast-ambiguous/
        cp tests/step0/Candidates.ql tests/ast-ambiguous/Ambiguous.ql
        cp tests/step0/Ambiguous.expected tests/ast-ambiguous/
        NIXQL_TEST_DUPLICATE_RAW=1 flock "$TMPDIR/codeql.lock" codeql test run \
          --search-path=${installed}:${packaging.library} \
          --threads=4 --ram=6000 tests/ast-ambiguous
        echo 'A0 Ast, Candidates, Ambiguous and table reconstruction with body/segment mutants passed'
        for suite in lexical lexical-dynamic lexical-extension lexical-gap lexical-merged lexical-siblings; do
          mkdir "tests/$suite"
          cp ${owner}/ql/test/"$suite"/* "tests/$suite/"
          chmod -R u+w "tests/$suite"
          for template in "tests/$suite/"*.nix.in; do
            cp "$template" "''${template%.in}"
          done
          flock "$TMPDIR/codeql.lock" codeql test run \
            --search-path=${installed}:${packaging.library} \
            --threads=4 --ram=6000 "tests/$suite"
        done
        python3 ${owner}/checks/run-domain-tests.py \
          ${owner}/checks/fixtures/lexical/test_dynamic.py \
          ${owner}/checks/fixtures/lexical/test_lexical.py \
          ${owner}/checks/fixtures/lexical/test_merged.py
        echo 'N1 NameBindings frozen positive, negative, duplicate and absent-model rows passed'
        mkdir "$out"
        printf 'S2 driver suite; 28 inherited raw/diagnostic preflight cases; Quality, Coordinates, Empty, Features and Ambiguous QL tests; exact archived bytes passed\n' > "$out/evidence"
      '';
  };
}
