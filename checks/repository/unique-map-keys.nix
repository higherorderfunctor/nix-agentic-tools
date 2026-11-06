{
  lib,
  pkgs,
}: let
  python = pkgs.python3.withPackages (ps: [ps.json5 ps.pyyaml]);
  script = pkgs.replaceVars ./unique-map-keys.py {
    nixInstantiate = lib.getExe pkgs.nix;
  };
  validator = import ../../lib/strict-shell-application.nix pkgs {
    name = "unique-map-keys";
    text = ''
      if [ "$#" -eq 0 ]; then
        echo "usage: unique-map-keys FILE..." >&2
        exit 2
      fi
      exec ${python}/bin/python ${script} "$@"
    '';
  };
  fixtures = ./fixtures/unique-map-keys;
  cases = {
    frontmatter-duplicate = {
      extension = "md";
      expected = "case.md: duplicate key /nested/a (line 4)";
      status = 1;
    };
    json-duplicate = {
      extension = "json";
      expected = "case.json: duplicate key /nested/a";
      status = 1;
    };
    json-multiple-findings = {
      extension = "json";
      expected = "case.json: duplicate key /first/a\ncase.json: duplicate key /second/b";
      status = 1;
    };
    json-pointer-escape = {
      extension = "json";
      expected = "case.json: duplicate key /nested/a~1b~0c";
      status = 1;
    };
    json-sibling-mappings = {
      extension = "json";
      expected = "";
      status = 0;
    };
    json5-duplicate = {
      extension = "json5";
      expected = "case.json5: duplicate key /nested/a";
      status = 1;
    };
    jsonc-duplicate = {
      extension = "jsonc";
      expected = "case.jsonc: duplicate key /nested/a";
      status = 1;
    };
    jsonl-duplicate = {
      extension = "jsonl";
      expected = "case.jsonl: duplicate key /nested/a";
      status = 1;
    };
    lock-json = {
      extension = "lock";
      expected = "case.lock: duplicate key /nested/a";
      status = 1;
    };
    lock-toml = {
      extension = "lock";
      expected = "case.lock: duplicate key /table/a: Cannot overwrite a value (at line 3, column 6)";
      status = 1;
    };
    markdown-no-frontmatter = {
      extension = "md";
      expected = "";
      status = 0;
    };
    nix = {
      extension = "nix";
      expected = ''case.nix: duplicate key /a: error: attribute 'a' already defined at case.nix:1:3'';
      status = 1;
    };
    toml-array-tables = {
      extension = "toml";
      expected = "";
      status = 0;
    };
    toml-direct = {
      extension = "toml";
      expected = "case.toml: duplicate key /a: Cannot overwrite a value (at line 2, column 6)";
      status = 1;
    };
    toml-dotted = {
      extension = "toml";
      expected = "case.toml: duplicate key /a/b: Cannot overwrite a value (at line 2, column 8)";
      status = 1;
    };
    toml-table = {
      extension = "toml";
      expected = ''case.toml: duplicate key /table: Cannot declare ('table',) twice (at line 3, column 7)'';
      status = 1;
    };
    yaml-merge = {
      extension = "yaml";
      expected = "";
      status = 0;
    };
    yaml-quoted-key = {
      extension = "yaml";
      expected = "case.yaml: duplicate key /nested/a (line 3)";
      status = 1;
    };
  };
  checkCase = name: case: ''
    cp --no-preserve=mode,ownership "${fixtures}/${name}.${case.extension}.fixture" case.${case.extension}
    got=""
    rc=0
    ${lib.getExe validator} case.${case.extension} >case.out 2>&1 || rc=$?
    got=$(cat case.out)
    want=${lib.escapeShellArg case.expected}
    if [ "$rc" -ne ${toString case.status} ] || [ "$got" != "$want" ]; then
      echo "FAIL ${name}: rc=$rc want=$want got=$got" >&2
      exit 1
    fi
    echo "ok ${name}"
  '';
in {
  package = validator;
  # A disabled detector exits the wrong status; a changed path or parser line
  # fails the hand-written diagnostic. Negative cases fail an over-broad hook.
  fixturesCheck = pkgs.runCommandLocal "unique-map-keys-fixtures-check" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    cd "$TMPDIR"
    ${lib.concatStrings (lib.mapAttrsToList checkCase cases)}
    mkdir -p "$out"
    touch "$out/ok"
  '';
}
