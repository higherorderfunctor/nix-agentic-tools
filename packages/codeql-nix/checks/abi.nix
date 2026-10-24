{
  lib,
  pkgs,
  self,
  ...
}: {
  checks = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
    codeql-nix-abi = let
      engine = self.ciPackages.${pkgs.stdenv.hostPlatform.system}.codeql-javascript;
      fixture = ./fixtures/abi;
      schema = ../schema;
    in
      pkgs.runCommand "codeql-nix-abi" {
        nativeBuildInputs = [engine pkgs.python3 pkgs.util-linux];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME" "$TMPDIR/pack"
        python3 ${fixture}/test_abi.py ${schema}/abi.py
        cp ${schema}/evaluation.dbscheme "$TMPDIR/pack/nix.dbscheme"
        printf '<dbstats><typesizes/><stats/></dbstats>\n' > "$TMPDIR/pack/nix.dbscheme.stats"
        cat > "$TMPDIR/pack/qlpack.yml" <<'PACK'
        name: nix-agentic-tools/nix-abi-check
        version: 0.0.0
        dbscheme: nix.dbscheme
        PACK
        printf 'select "schema-valid"\n' > "$TMPDIR/pack/Schema.ql"
        python3 - ${schema} ${fixture} "$TMPDIR/golden.trap" <<'PY'
        import importlib.util
        from pathlib import Path
        import sys
        sys.path.insert(0, sys.argv[2])
        from golden import BINDING_GRAPH as GRAPH
        spec = importlib.util.spec_from_file_location("abi", Path(sys.argv[1]) / "abi.py")
        abi = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(abi)
        assert abi.dbscheme() == (Path(sys.argv[1]) / "evaluation.dbscheme").read_text()
        labels = sorted({value for table, args in GRAPH
                         for (_, kind), value in zip(abi.COLUMNS[table], args)
                         if kind in abi.CONTRACT["entities"]})
        ids = {label: f"#{index}" for index, label in enumerate(labels, 1)}
        def quoted(value):
            return '"' + value.replace('"', '""') + '"'
        with open(sys.argv[3], "w") as trap:
            for label in labels:
                trap.write(f"{ids[label]}=@{quoted(label)}\n")
            for table, args in GRAPH:
                fields = [ids[value] if kind in abi.CONTRACT["entities"] else
                          quoted(value) if kind == "text" else
                          str(int(value)) if kind == "bool" else str(value)
                          for (_, kind), value in zip(abi.COLUMNS[table], args)]
                trap.write(f"{table}({','.join(fields)})\n")
        print(f"ABI import fixture: {len(GRAPH)} rows, {len(labels)} labels, {Path(sys.argv[3]).stat().st_size} bytes")
        PY
        flock "$TMPDIR/codeql.lock" codeql query compile --check-only --threads=4 --ram=6000 "$TMPDIR/pack/Schema.ql"
        flock "$TMPDIR/codeql.lock" codeql dataset import --threads=4 \
          --dbscheme="$TMPDIR/pack/nix.dbscheme" --fail-on-trap-errors \
          "$TMPDIR/dataset" "$TMPDIR/golden.trap"
        flock "$TMPDIR/codeql.lock" codeql dataset check "$TMPDIR/dataset"
        mkdir "$out"
        printf '34 relations; ABI behavioral tests and typed golden TRAP import passed\n' > "$out/evidence"
      '';
  };
}
