# Fixture suite for `unique-map-keys`. Each `<name>.<extension>.fixture` input
# is copied to `<name>.<extension>` and run through the exact validator
# derivation. Expected diagnostics are hand-written: a parser regression must
# change the observed text, not merely echo input.
{
  lib,
  pkgs,
  ...
}: {
  checks.unique-map-keys-fixtures = let
    uniqueMapKeys = import ./unique-map-keys.nix {inherit pkgs;};
    fixtures = ./fixtures/unique-map-keys;

    extensionOf = name: let
      fixture =
        lib.findSingle (f: lib.hasPrefix "${name}." f)
        "missing fixture" "several fixtures"
        (builtins.attrNames (builtins.readDir fixtures));
    in
      lib.removePrefix "${name}." (lib.removeSuffix ".fixture" fixture);

    cases = {
      frontmatter-duplicate.expected = "frontmatter-duplicate.md: duplicate key /nested/a (line 4)";
      json-array-duplicate.expected = "json-array-duplicate.json: duplicate key /0/a";
      json-duplicate.expected = "json-duplicate.json: duplicate key /nested/a";
      json-multiple-findings.expected = "json-multiple-findings.json: duplicate key /first/a\njson-multiple-findings.json: duplicate key /second/b";
      json-parse-error.expected = "json-parse-error.json: parse error: Expecting value: line 1 column 6 (char 5)";
      json-pointer-escape.expected = "json-pointer-escape.json: duplicate key /nested/a~1b~0c";
      json-sibling-mappings.expected = "";
      json5-duplicate.expected = "json5-duplicate.json5: duplicate key /nested/a";
      jsonc-duplicate.expected = "jsonc-duplicate.jsonc: duplicate key /nested/a";
      jsonl-duplicate.expected = "jsonl-duplicate.jsonl: duplicate key /0/a (line 2)";
      lock-json.expected = "lock-json.lock: duplicate key /nested/a";
      lock-toml.expected = "lock-toml.lock: Cannot overwrite a value (at line 3, column 6)";
      markdown-no-frontmatter.expected = "";
      markdown-thematic-break.expected = "";
      nix-batch = {
        files = ["nix-batch-clean" "nix-batch-duplicate" "nix-batch-syntax"];
        # Nix's own first two diagnostic lines, path rewritten to the given filename.
        expected = "error: attribute 'a' already defined at nix-batch-duplicate.nix:1:3\n       at nix-batch-duplicate.nix:1:10:\nerror: syntax error, unexpected end of file, expecting '.' or '='\n       at nix-batch-syntax.nix:2:1:";
      };
      toml-array-tables.expected = "";
      toml-direct.expected = "toml-direct.toml: Cannot overwrite a value (at line 2, column 6)";
      toml-dotted.expected = "toml-dotted.toml: Cannot overwrite a value (at line 2, column 8)";
      toml-table.expected = "toml-table.toml: Cannot declare ('table',) twice (at line 3, column 7)";
      yaml-alias-duplicate.expected = "yaml-alias-duplicate.yaml: duplicate key /base/a (line 1)";
      yaml-merge.expected = "";
      yaml-merge-sequence.expected = "";
      yaml-multi-document.expected = "yaml-multi-document.yaml: duplicate key /nested/a (line 5)";
      yaml-quoted-key.expected = "yaml-quoted-key.yaml: duplicate key /nested/a (line 3)\nyaml-quoted-key.yaml: duplicate key /nested/a (line 4)";
      yaml-sibling-mappings.expected = "";
    };

    checkCase = name: case: let
      targets = map (file: "${file}.${extensionOf file}") (case.files or [name]);
      status =
        if case.expected == ""
        then 0
        else 1;
      copyOne = target: ''
        cp --no-preserve=mode,ownership "${fixtures}/${target}.fixture" "$TMPDIR/${target}"
      '';
    in ''
      ${lib.concatStrings (map copyOne targets)}
      rc=0
      ${lib.getExe uniqueMapKeys} ${toString targets} >case.out 2>&1 || rc=$?
      got=$(cat case.out)
      want=${lib.escapeShellArg case.expected}
      if [ "$rc" -ne ${toString status} ] || [ "$got" != "$want" ]; then
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
