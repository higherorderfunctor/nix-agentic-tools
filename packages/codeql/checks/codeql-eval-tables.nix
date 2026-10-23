# Evaluate tiny generic modules, then run the actual fallback against their facts.
{
  lib,
  pkgs,
  self,
  ...
}: {
  checks = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
    codeql-eval-tables = let
      packages = self.ciPackages.${pkgs.stdenv.hostPlatform.system};
      nixCodeql = packages.codeql-extractor-nix.codeql;
      args = import ./fixtures/eval-project {inherit lib;};
      rows = (import ../lib/eval-tables.nix {inherit lib;}) {
        inherit (args) modules result;
        root = ../../..;
        source = "fixture";
      };
      inactive = lib.filter (row: row.path == "inactive" && !row.active) rows.definition;
      forwarding = lib.filter (row: row.aliasForward) rows.definition;
      concrete = [
        "direct.enabled"
        "groups.a.b.enabled"
        "instances.first.enabled"
        ''listInstances."[definition 1-entry 1]".enabled''
        ''mixed.a."[definition 1-entry 1]".enabled''
      ];
      hasDefinition = path: priority: kind: wins:
        lib.any (row: row.path == path && row.priority == priority && row.kind == kind && row.active && row.wins == wins) rows.definition;
      expected = pkgs.writeText "losing-default-paths.json" (builtins.toJSON (map (path: [path]) (["enabled"] ++ concrete ++ ["structured" "throwing"])));
      facts = pkgs.writeText "eval-tables.json" (builtins.toJSON rows);
    in
      assert lib.length inactive == 1;
      assert forwarding != [];
      assert lib.all (path:
        hasDefinition path 100 "bool" true
        && hasDefinition path 1000 "bool" false
        && lib.any (row: row.path == path && row.isDefined) rows.option
        && lib.any (row: row.path == path && row.kind == "bool" && row.value == "true") rows.value)
      concrete;
      assert hasDefinition "throwing" 1000 "unknown" false;
      assert hasDefinition "throwing" 100 "bool" true;
      assert lib.any (row: row.path == "throwing" && row.kind == "bool" && row.value == "true") rows.value;
      assert lib.any (row: row.path == "throwing" && row.priority == 1000 && row.line > 0 && row.column > 0 && row.file != "" && row.moduleFile != "") rows.definition;
      assert hasDefinition "structured" 1000 "set" false;
      assert hasDefinition "tagged" 100 "set" true;
      assert lib.any (row: row.disabled && lib.hasSuffix "/disabled.nix" row.file) rows.module;
      assert lib.all (row: !(lib.hasSuffix "/disabled.nix" row.moduleFile)) rows.definition;
      assert lib.any (row: row.path == "synthetic" && row.line == -1 && row.column == -1) rows.option_decl;
      assert lib.any (row: row.path == "synthetic" && row.generated) rows.option;
        pkgs.runCommand "codeql-eval-tables" {
          nativeBuildInputs = [pkgs.python3 pkgs.jq];
        } ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          export HOME="$TMPDIR" LC_ALL=C
          ${lib.getExe nixCodeql.createDatabase} "$TMPDIR/fixture" ${./fixtures/eval-project}
          ln -s ${nixCodeql.engine} "$TMPDIR/fixture/engine"
          python3 - ${../src/eval_tables.py} ${facts} "$TMPDIR/fixture/eval" <<'PY'
          import importlib.util, json, pathlib, sys
          spec = importlib.util.spec_from_file_location("tables", sys.argv[1])
          module = importlib.util.module_from_spec(spec)
          spec.loader.exec_module(module)
          module.render(json.load(open(sys.argv[2])), pathlib.Path(sys.argv[3]))
          PY
          ${lib.getExe packages.codeql-query} run --no-daemon "$TMPDIR/fixture" \
            ${./fixtures/eval-project}/LosingDefault.ql > "$TMPDIR/result.json"
          jq -e --slurpfile expected ${expected} '.tuples == ($expected[0] | sort)' "$TMPDIR/result.json"
          python3 - ${../src/query.py} ${nixCodeql.engine} "$TMPDIR/fixture/db" \
            ${./fixtures/eval-project}/LosingDefault.ql "$TMPDIR/result.json" <<'PY'
          import importlib.util, json, pathlib, sys
          spec = importlib.util.spec_from_file_location("query", sys.argv[1])
          module = importlib.util.module_from_spec(spec)
          spec.loader.exec_module(module)
          server = module.QueryServer(pathlib.Path(sys.argv[3]), sys.argv[2] + "/bin/codeql", pathlib.Path("cache"), 4, 6000)
          try:
              output = pathlib.Path("daemon.bqrs")
              server.run(pathlib.Path(sys.argv[4]), output)
              assert module.decode(sys.argv[2] + "/bin/codeql", output, "0") == json.load(open(sys.argv[5]))
          finally:
              server.close()
          PY
          cp "$TMPDIR/result.json" "$out"
        '';
  };
}
