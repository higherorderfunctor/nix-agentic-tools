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

    targetFor = name: let
      fixture =
        lib.findSingle (f: lib.hasPrefix "${name}." f)
        "missing fixture" "several fixtures"
        (builtins.attrNames (builtins.readDir fixtures));
    in
      lib.removeSuffix ".fixture" fixture;

    targetsFor = name: case: map targetFor (case.files or [name]);

    cases = {
      # An indented --- inside a block scalar is content, not a closing fence;
      # the duplicate after it must still be found.
      frontmatter-block-scalar.expected = "frontmatter-block-scalar.md: duplicate key /nested/a (line 7)";
      # Do not stop scanning a document after the first finding.
      json-multiple-findings.expected = "json-multiple-findings.json: duplicate key /first/a\njson-multiple-findings.json: duplicate key /second/b";
      # A malformed value must produce a parse diagnostic, not a duplicate diagnostic.
      json-parse-error.expected = "json-parse-error.json: parse error: Expecting value: line 1 column 6 (char 5)";
      # Literal slashes and tildes in a key must not change the pointer's meaning.
      json-pointer-escape.expected = "json-pointer-escape.json: duplicate key /nested/a~1b~0c";
      # JSON5 unquoted keys must reach the duplicate scan rather than the JSON parser.
      json5-duplicate.expected = "json5-duplicate.json5: duplicate key /nested/a";
      # JSONC comments and trailing commas must not prevent duplicate detection.
      jsonc-duplicate.expected = "jsonc-duplicate.jsonc: duplicate key /nested/a";
      # A duplicate in the second record must keep its physical line number.
      jsonl-duplicate.expected = "jsonl-duplicate.jsonl: duplicate key /0/a (line 2)";
      # JSON and TOML lock files share an extension but need different parsers.
      lock-json.expected = "lock-json.lock: duplicate key /nested/a";
      lock-toml.expected = "lock-toml.lock: Cannot overwrite a value (at line 3, column 6)";
      # An opening thematic break without a closing fence is not frontmatter.
      markdown-thematic-break.expected = "";
      nix-batch = {
        # The fallback must find both errors after a clean file, not stop at the duplicate.
        files = ["nix-batch-clean" "nix-batch-duplicate" "nix-batch-syntax"];
        # Nix's own first two diagnostic lines, path rewritten to the given filename.
        expected = "error: attribute 'a' already defined at nix-batch-duplicate.nix:1:3\n       at nix-batch-duplicate.nix:1:10:\nerror: syntax error, unexpected end of file, expecting '.' or '='\n       at nix-batch-syntax.nix:2:1:";
      };
      # Redeclaring a table fails even when no value is overwritten.
      toml-table.expected = "toml-table.toml: Cannot declare ('table',) twice (at line 3, column 7)";
      # Reusing an anchor must not report the same source duplicate at each alias.
      yaml-alias-duplicate.expected = "yaml-alias-duplicate.yaml: duplicate key /base/a (line 1)";
      # An explicit key may override a key from an anchor without duplicating it.
      yaml-merge.expected = "";
      # A key shared by separate merge sources is not a duplicate in the recipient.
      yaml-merge-sequence.expected = "";
      # Reading just the first YAML document would miss the second one's repeat.
      yaml-multi-document.expected = "yaml-multi-document.yaml: duplicate key /nested/a (line 5)";
      # Spelling a key with quotes must not change its identity, and all repeats count.
      yaml-quoted-key.expected = "yaml-quoted-key.yaml: duplicate key /nested/a (line 3)\nyaml-quoted-key.yaml: duplicate key /nested/a (line 4)";
    };

    fixtureTargets = lib.concatLists (lib.mapAttrsToList targetsFor cases);
    copyFixture = target: ''
      cp --no-preserve=mode,ownership "${fixtures}/${target}.fixture" "$TMPDIR/${target}"
    '';

    checkCase = name: case: let
      status =
        if case.expected == ""
        then 0
        else 1;
    in ''
      rc=0
      ${lib.getExe uniqueMapKeys} ${toString (targetsFor name case)} >case.out 2>&1 || rc=$?
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
      ${lib.concatStrings (map copyFixture fixtureTargets)}
      ${lib.concatStrings (lib.mapAttrsToList checkCase cases)}
      mkdir -p "$out"
      touch "$out/ok"
    '';
}
