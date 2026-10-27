{
  lib,
  pkgs,
  self,
  ...
}: {
  checks = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
    codeql-nix-bootstrap = let
      # Engine and pinned inputs.
      engine = self.ciPackages.${pkgs.stdenv.hostPlatform.system}.codeql-javascript;
      fixture = ./fixtures/bootstrap;
      grammar = pkgs.fetchFromGitHub {
        hash = "sha256-sS39i8TCtArwKoq3DFpxaaeZEuRiC1DUTZVPJ+mcPfE=";
        owner = "nix-community";
        repo = "tree-sitter-nix";
        rev = "38a15330421d20f3a4d380759f9634d39ba3d8ec";
      };
      kit = pkgs.fetchFromGitHub {
        hash = "sha256-o9cS+5joKXdUN8fOuUyl/yMMIzI4sKxdotljfMJ5by0=";
        owner = "github";
        repo = "codeql";
        rev = "a1575b98a8cc19bcfa7bb6cb41be688cb3dae65c";
      };
      inherit (builtins.fromJSON (builtins.readFile ../../codeql/sources.json)) version;

      # Rust fixture and reproducible Cargo inputs.
      extractor = pkgs.rustPlatform.buildRustPackage {
        cargoHash = "sha256-ewSoza879MQSji9vVZxP81htnxSnDURD9T+iYMEhzrw=";
        doCheck = false;
        pname = "nixql-bootstrap";
        src = source;
        version = "0.0.0";
      };
      source = pkgs.runCommand "nixql-bootstrap-source" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        mkdir -p "$out/upstream/shared"
        cp ${fixture + "/Cargo.toml"} "$out/Cargo.toml"
        cp ${fixture + "/Cargo.lock"} "$out/Cargo.lock"
        cp -r ${fixture + "/src"} "$out/src"
        for crate in tree-sitter-extractor yeast yeast-macros yeast-schema; do
          cp -r ${kit}/shared/"$crate" "$out/upstream/shared/"
        done
        cp -r ${grammar} "$out/grammar"
      '';

      # Installed entry points.
      build = strictShell {
        name = "autobuild.sh";
        text = ''
          "$CODEQL_DIST/codeql" database index-files \
            --language=nix --include-extension=.nix --working-dir=. \
            "$CODEQL_EXTRACTOR_NIX_WIP_DATABASE"
          exec ${extractor}/bin/bootstrap evaluation
        '';
      };
      index = strictShell {
        name = "index-files.sh";
        text = ''
          exec ${extractor}/bin/bootstrap syntax "$1"
        '';
      };
      strictShell = import ../../../lib/strict-shell-application.nix pkgs;

      # Extractor and library layout.
      installed = pkgs.runCommand "nixql-bootstrap-packs" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        mkdir -p "$out/extractor/tools" "$out/library"
        cp -r ${fixture}/ql/. "$out/library/"
        chmod -R u+w "$out/library"
        ${extractor}/bin/bootstrap generate "$out/library/nix.dbscheme" "$out/library/Ast.qll"
        cp "$out/library/nix.dbscheme" "$out/extractor/nix.dbscheme"
        printf '<dbstats><typesizes/><stats/></dbstats>\n' > "$out/library/nix.dbscheme.stats"
        cp "$out/library/nix.dbscheme.stats" "$out/extractor/nix.dbscheme.stats"
        cat > "$out/extractor/codeql-extractor.yml" <<'MANIFEST'
        build_modes: [none]
        column_kind: utf8
        display_name: Nix bootstrap
        file_types:
          - extensions: [.nix]
            name: nix
        legacy_qltest_extraction: true
        name: nix
        version: 0.0.0
        MANIFEST
        ln -s ${index}/bin/index-files.sh "$out/extractor/tools/index-files.sh"
        ln -s ${build}/bin/autobuild.sh "$out/extractor/tools/autobuild.sh"
        ln -s ${build}/bin/autobuild.sh "$out/extractor/tools/qltest.sh"
      '';
    in
      assert lib.assertMsg (version == "2.27.3") "codeql-nix-bootstrap: re-audit the kit pin when the engine changes";
        pkgs.runCommand "codeql-nix-bootstrap" {
          nativeBuildInputs = [engine pkgs.python3];
        } ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME" "$TMPDIR/tests"
          test "$(codeql version --format=terse)" = ${lib.escapeShellArg version}
          cp -r ${fixture}/test/. "$TMPDIR/tests/"
          chmod -R u+w "$TMPDIR/tests"
          python3 - "$TMPDIR/tests" <<'PY'
          from pathlib import Path
          import sys
          root = Path(sys.argv[1])
          for template in root.glob("*.nix.in"):
              data = template.read_bytes()
              if template.name == "coordinates.nix.in":
                  data = data.replace(b"\n", b"\r\n")
              template.with_suffix("").write_bytes(data)
          PY
          python3 ${fixture}/test-preflight.py --probe ${extractor}/bin/bootstrap-probe --evaluation ${extractor}/bin/bootstrap --scratch "$TMPDIR/preflight"
          codeql resolve languages --search-path=${installed}/extractor --format=json > languages.json
          python3 - <<'PY'
          import json
          assert "nix" in json.load(open("languages.json")), "extractor not discovered"
          PY
          codeql test run --search-path=${installed}/extractor:${installed}/library \
            --threads=4 --ram=6000 "$TMPDIR/tests"
          mkdir -p "$TMPDIR/empty"
          if codeql resolve extractor --language=nix --search-path="$TMPDIR/empty" > missing-extractor.log 2>&1; then
            echo "missing extractor unexpectedly resolved" >&2
            exit 1
          fi
          cat missing-extractor.log
          if codeql query compile --search-path="$TMPDIR/empty" "$TMPDIR/tests/Join.ql" > missing-library.log 2>&1; then
            echo "missing library unexpectedly resolved" >&2
            exit 1
          fi
          cat missing-library.log
          mkdir "$out"
          printf 'CLI %s\nkit %s\ngrammar %s\n28 raw/diagnostic and 3 evaluation preflight cases; joined and raw qltests passed\n' \
            ${lib.escapeShellArg version} ${kit.rev} ${grammar.rev} > "$out/evidence"
        '';
  };
}
