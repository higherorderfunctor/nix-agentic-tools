# Fixture suite for `unique-map-keys`. Expected diagnostics are hand-written:
# a parser regression must change the observed text, not merely echo input.
{
  lib,
  pkgs,
  ...
}: {
  checks.unique-map-keys-fixtures = let
    uniqueMapKeys = import ./unique-map-keys.nix {inherit pkgs;};
    fixtures = ./fixtures/unique-map-keys;

    cases = {
      frontmatter-duplicate = {
        files = [{extension = "md";}];
        expected = "case.md: duplicate key /nested/a (line 4)";
        status = 1;
      };
      json-array-duplicate = {
        files = [{extension = "json";}];
        expected = "case.json: duplicate key /0/a";
        status = 1;
      };
      json-duplicate = {
        files = [{extension = "json";}];
        expected = "case.json: duplicate key /nested/a";
        status = 1;
      };
      json-multiple-findings = {
        files = [{extension = "json";}];
        expected = "case.json: duplicate key /first/a\ncase.json: duplicate key /second/b";
        status = 1;
      };
      json-parse-error = {
        files = [{extension = "json";}];
        expected = "case.json: parse error: Expecting value: line 1 column 6 (char 5)";
        status = 1;
      };
      json-pointer-escape = {
        files = [{extension = "json";}];
        expected = "case.json: duplicate key /nested/a~1b~0c";
        status = 1;
      };
      json-sibling-mappings = {
        files = [{extension = "json";}];
        expected = "";
        status = 0;
      };
      json5-duplicate = {
        files = [{extension = "json5";}];
        expected = "case.json5: duplicate key /nested/a";
        status = 1;
      };
      jsonc-duplicate = {
        files = [{extension = "jsonc";}];
        expected = "case.jsonc: duplicate key /nested/a";
        status = 1;
      };
      jsonl-duplicate = {
        files = [{extension = "jsonl";}];
        expected = "case.jsonl: duplicate key /0/a (line 2)";
        status = 1;
      };
      lock-json = {
        files = [{extension = "lock";}];
        expected = "case.lock: duplicate key /nested/a";
        status = 1;
      };
      lock-toml = {
        files = [{extension = "lock";}];
        expected = "case.lock: duplicate key: Cannot overwrite a value (at line 3, column 6)";
        status = 1;
      };
      markdown-no-frontmatter = {
        files = [{extension = "md";}];
        expected = "";
        status = 0;
      };
      markdown-thematic-break = {
        files = [{extension = "md";}];
        expected = "";
        status = 0;
      };
      nix-batch = {
        files = [
          {
            name = "nix-batch-clean";
            extension = "nix";
            target = "nix-batch-clean.nix";
          }
          {
            name = "nix-batch-duplicate";
            extension = "nix";
            target = "nix-batch-duplicate.nix";
          }
          {
            name = "nix-batch-syntax";
            extension = "nix";
            target = "nix-batch-syntax.nix";
          }
        ];
        expected = ''
          nix-batch-duplicate.nix: duplicate key /a: error: attribute 'a' already defined at nix-batch-duplicate.nix:1:3
          nix-batch-syntax.nix: parse error: error: syntax error, unexpected end of file, expecting '.' or '=' at nix-batch-syntax.nix:2:1'';
        status = 1;
      };
      toml-array-tables = {
        files = [{extension = "toml";}];
        expected = "";
        status = 0;
      };
      toml-direct = {
        files = [{extension = "toml";}];
        expected = "case.toml: duplicate key: Cannot overwrite a value (at line 2, column 6)";
        status = 1;
      };
      toml-dotted = {
        files = [{extension = "toml";}];
        expected = "case.toml: duplicate key: Cannot overwrite a value (at line 2, column 8)";
        status = 1;
      };
      toml-table = {
        files = [{extension = "toml";}];
        expected = "case.toml: duplicate key: Cannot declare ('table',) twice (at line 3, column 7)";
        status = 1;
      };
      yaml-merge-sequence = {
        files = [{extension = "yaml";}];
        expected = "";
        status = 0;
      };
      yaml-multi-document = {
        files = [{extension = "yaml";}];
        expected = "case.yaml: duplicate key /nested/a (line 5)";
        status = 1;
      };
      yaml-quoted-key = {
        files = [{extension = "yaml";}];
        expected = "case.yaml: duplicate key /nested/a (line 3)";
        status = 1;
      };
    };

    checkCase = name: case: let
      copyOne = file: let
        sourceName = file.name or name;
        target = file.target or "case.${file.extension}";
      in ''
        cp --no-preserve=mode,ownership "${fixtures}/${sourceName}.${file.extension}.fixture" "$TMPDIR/${target}"
      '';
      targets = map (file: file.target or "case.${file.extension}") case.files;
    in ''
      ${lib.concatStrings (map copyOne case.files)}
      rc=0
      ${lib.getExe uniqueMapKeys.package} ${toString targets} >case.out 2>&1 || rc=$?
      got=$(cat case.out)
      want=${lib.escapeShellArg case.expected}
      if [ "$rc" -ne ${toString case.status} ] || [ "$got" != "$want" ]; then
        echo "FAIL ${name}: rc=$rc want=$want got=$got" >&2
        exit 1
      fi
      echo "ok ${name}"
    '';
  in
    pkgs.runCommandLocal "unique-map-keys-fixtures-check" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      cd "$TMPDIR"
      ${lib.concatStrings (lib.mapAttrsToList checkCase cases)}
      mkdir -p "$out"
      touch "$out/ok"
    '';
}
