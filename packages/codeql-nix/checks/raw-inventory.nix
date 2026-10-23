{
  lib,
  pkgs,
  self,
  ...
}: {
  checks = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
    codeql-nix-raw-inventory = let
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
          exec ${packaging.syntaxFixture}/bin/bootstrap syntax "$1"
        '';
      };
      installed = pkgs.runCommand "nixql-raw-inventory-extractor" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        mkdir -p "$out/tools"
        cp ${packaging.generated}/nix.dbscheme "$out/nix.dbscheme"
        printf '<dbstats><typesizes/><stats/></dbstats>\n' > "$out/nix.dbscheme.stats"
        cat > "$out/codeql-extractor.yml" <<'MANIFEST'
        build_modes: [none]
        column_kind: utf8
        display_name: Nix inventory fixture
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
      packaging = import ../lib/packaging.nix {inherit lib pkgs;};
      strictShell = import ../../../lib/strict-shell-application.nix pkgs;
    in
      pkgs.runCommand "codeql-nix-raw-inventory" {
        nativeBuildInputs = [engine pkgs.python3];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME" first second tests
        ${packaging.generator}/bin/nixql-generate first
        ${packaging.generator}/bin/nixql-generate second
        diff -r first second
        diff -r first ${packaging.generated}
        diff -r first ${owner}/generated
        python3 ${./fixtures/raw-inventory/test_inventory.py} \
          ${packaging.generated} ${owner}/schema/contract.json
        cp ${owner}/ql/test/qlpack.yml tests/
        cp -r ${owner}/ql/test/raw-inventory tests/
        chmod -R u+w tests
        for template in tests/raw-inventory/*.nix.in; do
          cp "$template" "''${template%.in}"
        done
        codeql test run --search-path=${installed}:${packaging.library} \
          --threads=4 --ram=6000 --keep-databases tests/raw-inventory
        archive=tests/raw-inventory/raw-inventory.testproj/src
        python3 ${./fixtures/raw-inventory/validate_archive.py} "$archive" tests/raw-inventory
        for mutation in missing corrupt; do
          python3 - "$archive" "$mutation" <<'PY'
        from pathlib import Path
        import sys

        target = Path(sys.argv[1]) / (Path("tests/raw-inventory").resolve() / "selected.nix").as_posix().lstrip("/")
        if sys.argv[2] == "missing":
            target.unlink()
        else:
            target.write_bytes(b"corrupted archive bytes")
        PY
          if python3 ${./fixtures/raw-inventory/validate_archive.py} "$archive" tests/raw-inventory \
            > "$mutation-archive.log" 2>&1; then
            echo "$mutation source archive unexpectedly accepted" >&2
            exit 1
          fi
          cat "$mutation-archive.log"
          grep -q "$mutation archived fixture: selected.nix" "$mutation-archive.log"
        done
        cp -r ${packaging.library} missing-location
        chmod -R u+w missing-location
        rm missing-location/codeql/Locations.qll
        if codeql query compile --threads=4 --ram=6000 --search-path=${installed}:"$PWD/missing-location" \
          tests/raw-inventory/Locations.ql > missing-location.log 2>&1; then
          echo "missing local Locations adapter unexpectedly compiled" >&2
          exit 1
        fi
        cat missing-location.log
        grep -q 'codeql.Locations' missing-location.log
        mkdir "$out"
        printf 'deterministic generation; manifest inventory; standalone location rows, exact archived bytes, missing/corrupt-archive and missing-adapter refusals passed\n' > "$out/evidence"
      '';
  };
}
