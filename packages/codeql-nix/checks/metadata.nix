{
  lib,
  pkgs,
  self,
  ...
}: {
  checks = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
    codeql-nix-metadata = let
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
          ${pkgs.coreutils}/bin/mkdir -p "$CODEQL_EXTRACTOR_NIX_TRAP_DIR"
          exec ${pkgs.python3}/bin/python3 ${./fixtures/metadata/fixture.py} \
            "$CODEQL_EXTRACTOR_NIX_TRAP_DIR/metadata.trap" ${../schema}/abi.py
        '';
      };
      installed = pkgs.runCommand "nixql-metadata-fixture-extractor" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        mkdir -p "$out/tools"
        cp ${packaging.generated}/nix.dbscheme "$out/nix.dbscheme"
        printf '<dbstats><typesizes/><stats/></dbstats>\n' > "$out/nix.dbscheme.stats"
        cat > "$out/codeql-extractor.yml" <<'MANIFEST'
        build_modes: [none]
        column_kind: utf8
        display_name: Nix handwritten metadata fixture
        file_types:
          - extensions: [.nix]
            name: nix
        legacy_qltest_extraction: true
        name: nix
        version: 0.0.0
        MANIFEST
        ln -s ${index}/bin/index-files.sh "$out/tools/index-files.sh"
        ln -s ${build}/bin/qltest.sh "$out/tools/qltest.sh"
      '';
      packaging = import ../lib/packaging.nix {inherit lib pkgs;};
      strictShell = import ../../../lib/strict-shell-application.nix pkgs;
    in
      pkgs.runCommand "codeql-nix-metadata" {
        nativeBuildInputs = [engine pkgs.python3 pkgs.util-linux];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME" tests/metadata
        cp ${../ql/test/qlpack.yml} tests/qlpack.yml
        cp ${../ql/test/step0/Metadata.ql} tests/metadata/Metadata.ql
        cp ${../ql/test/step0/Metadata.expected} tests/metadata/Metadata.expected
        cp ${../ql/test/step0/UnknownOrigin.ql} tests/metadata/UnknownOrigin.ql
        cp ${../ql/test/step0/UnknownOrigin.expected} tests/metadata/UnknownOrigin.expected
        printf 'null\n' > tests/metadata/marker.nix
        flock "$TMPDIR/codeql.lock" codeql test run \
          --search-path=${installed}:${packaging.library} \
          --threads=4 --ram=6000 tests/metadata
        echo 'L0 Metadata and Q0 UnknownOrigin: missing-file selected/declaration rows; handwritten success/failure, exact paths, target separation, signed endpoints, origins, unknown selection, typed subject paths and sparse definition observations passed'
        mkdir "$out"
        printf 'L0 Metadata QL contract oracle passed\n' > "$out/evidence"
      '';
  };
}
