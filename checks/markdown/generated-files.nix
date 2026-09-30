# cspell:ignore FEFF
# Behavioral fixtures for the generated store-tree builder. Failure cases run
# the builder's real phases in fresh shells: a check derivation cannot invoke
# nested nix builds in its sandbox. The final case builds one failing mkTree
# through nixpkgs' testBuildFailure to pin the stdenv install-check lifecycle.
{
  inputs,
  lib,
  pkgs,
  ...
}: let
  generated = import ../../lib/generated.nix {inherit lib;} pkgs;
  frontmatter = import ../../lib/frontmatter.nix {inherit lib;};
  mkFile = type: text: {inherit type text;};
  markdown = text: {"page.md" = mkFile "markdown" text;};
  markedMarkdown = text: {"page.md" = mkFile "markdown" text // {frontmatter = true;};};
  consumerData = {
    description = "Generated Kiro steering description is long enough for the default Markdown formatter to demonstrate whether it reflows YAML frontmatter plain scalars across lines while preserving parsed content.";
    fileMatchPattern = ["SCHEMA.md" "bin/**" "devenv.nix" "nix/kiro/agents/**" "nix/skills/**"];
    inclusion = "fileMatch";
    name = "f1-probe";
  };
  consumerRendered = frontmatter.render {
    data = consumerData;
    body = "# Page\n";
  };
  consumerFiles = {"page.md" = {type = "markdown";} // frontmatter.treeFile consumerRendered;};
  # Inject one broken attach step to prove the byte guard catches it.
  guardScript = ../../lib/generated-guard.py;
  bytesChanged = "installed Markdown frontmatter bytes differ from the generator bytes";
  attachCommand = script: "${script} attach";
  patchedGuard = name: replacement: let
    source = builtins.readFile guardScript;
    anchor = "prefix = header_file.read_bytes()";
  in
    assert lib.assertMsg (lib.hasInfix anchor source) "generated-files: the attach anchor moved in lib/generated-guard.py";
      pkgs.writeText "generated-guard-${name}.py" (builtins.replaceStrings [anchor] [replacement] source);
  brokenAttach = patchedGuard "truncated" ''prefix = re.sub(rb"[^\n]*\n(---\n)\Z", rb"\1", header_file.read_bytes())'';
  withAttach = script: phase: let
    replaced = builtins.replaceStrings [(attachCommand guardScript)] [(attachCommand script)] phase;
  in
    if script == null
    then phase
    else assert lib.assertMsg (replaced != phase) "generated-files: mkTree no longer calls the guard attach step"; replaced;
  bom = builtins.fromJSON ''"\uFEFF"'';
  crlf = builtins.replaceStrings ["\n"] ["\r\n"];
  dataFile = type: text: {"data.${type}" = mkFile type text;};
  noFormat = {
    json = null;
    markdown = null;
    toml = null;
    yaml = null;
  };
  badTable = ''    | a | b |
    | --- | --- |
    | x | y | z |
  '';
  goodTable = ''    | a | b |
    | --- | --- |
    | x | y |
  '';
  badHeader = ''    | a | b | c |
    | --- | --- |
    | x | y |
  '';
  cases = [
    {
      name = "format-json";
      files = {config = mkFile "json" ''{"a":true}'';};
      formatter = generated.defaultFormatter;
      guards.parseCompare = true;
      changed = "config";
    }
    {
      name = "format-markdown";
      files =
        markdown ''          #   Heading
        '';
      formatter = generated.defaultFormatter;
      guards.parseCompare = true;
      changed = "page.md";
    }
    {
      name = "format-toml";
      files = {config = mkFile "toml" "a=1\n";};
      formatter = generated.defaultFormatter;
      guards.parseCompare = true;
      changed = "config";
    }
    {
      name = "format-yaml";
      files =
        dataFile "yaml" ''          a:    true
        '';
      formatter = generated.defaultFormatter;
      guards.parseCompare = true;
      changed = "data.yaml";
    }
    {
      name = "formatter-replaces-default";
      files =
        markdown ''          # Original
        '';
      formatter = noFormat // {markdown = "printf '# Custom\\n' > page.md";};
      expected = "# Custom\n";
      path = "page.md";
    }
    {
      name = "null-disables-formatter";
      files =
        markdown ''          #   Original
        '';
      formatter = noFormat;
      expected = "#   Original\n";
      path = "page.md";
    }
    {
      name = "cache-is-not-installed";
      files =
        markdown ''          # Original
        '';
      formatter = noFormat // {markdown = "mkdir -p .cache; printf state > .cache/state";};
      absent = ".cache/state";
    }
    {
      name = "formatter-deletes-declared-file";
      files = markdown "# Page\n";
      formatter = noFormat // {markdown = "rm page.md";};
      fails = "formatter removed page.md";
    }
    {
      name = "table-cells-good";
      files = markdown goodTable;
      formatter = noFormat;
      guards.tableCells = true;
    }
    {
      name = "table-cells-bad";
      files = markdown badTable;
      formatter = noFormat;
      guards.tableCells = true;
      fails = "tableCells";
    }
    {
      name = "table-cells-header-before-format";
      files = markdown badHeader;
      formatter = generated.defaultFormatter;
      guards.tableCells = true;
      fails = "tableCells";
    }
    {
      name = "table-cells-disabled";
      files = markdown badTable;
      formatter = noFormat;
      guards.tableCells = false;
    }
    {
      name = "user-check-cannot-change-output";
      files = markdown goodTable;
      formatter = noFormat;
      guards.tableCells = true;
      check.markdown = "printf '%s' ${lib.escapeShellArg badTable} > page.md";
      checked = badTable;
      expected = goodTable;
      path = "page.md";
    }
    {
      name = "split-code-spans-good";
      files =
        markdown ''          A `single span` is sound.
        '';
      formatter = noFormat;
      guards.splitCodeSpans = true;
    }
    {
      name = "split-code-spans-bad";
      files = markdown ''        A `split
        span` is broken.
      '';
      formatter = noFormat;
      guards.splitCodeSpans = true;
      fails = "splitCodeSpans";
    }
    {
      name = "split-code-spans-disabled";
      files = markdown ''        A `split
        span` is broken.
      '';
      formatter = noFormat;
      guards.splitCodeSpans = false;
    }
    {
      name = "parse-json-good";
      files = dataFile "json" ''{"value":true}'';
      formatter = noFormat;
      guards.parseCompare = true;
    }
    {
      name = "parse-json-bad";
      files = dataFile "json" ''{"value":true}'';
      formatter = noFormat // {json = "printf '{\"value\":1}' > data.json";};
      guards.parseCompare = true;
      fails = "parseCompare";
    }
    {
      name = "parse-json-disabled";
      files = dataFile "json" ''{"value":true}'';
      formatter = noFormat // {json = "printf '{\"value\":1}' > data.json";};
      guards.parseCompare = false;
    }
    {
      name = "parse-toml-bad";
      files =
        dataFile "toml" ''          value = true
        '';
      formatter = noFormat // {toml = "printf 'value = 1\\n' > data.toml";};
      guards.parseCompare = true;
      fails = "parseCompare";
    }
    {
      name = "parse-yaml-bad";
      files =
        dataFile "yaml" ''          value: true
        '';
      formatter = noFormat // {yaml = "printf 'value: 1\\n' > data.yaml";};
      guards.parseCompare = true;
      fails = "parseCompare";
    }
    {
      name = "frontmatter-consumer-default-bytes";
      files = consumerFiles;
      formatter = generated.defaultFormatter;
      guards.parseCompare = true;
      head = frontmatter.block consumerData + "\n";
    }
    {
      name = "parse-unmarked-formatter-adds-mapping-bad";
      files = markdown "# Page\n";
      formatter = noFormat // {markdown = "printf '%s\\n' '---' 'value: true' '---' '# Page' > page.md";};
      fails = "without its marker";
    }
    {
      name = "parse-thematic-pair-good";
      files = markdown ''        ---

        # Heading

        Ordinary prose without a mapping.

        ---
      '';
      formatter = generated.defaultFormatter;
      guards.parseCompare = true;
    }
    {
      name = "parse-frontmatter-bom-good";
      files = markedMarkdown (bom + "---\nvalue: true\n---\n\n\n# Page\n");
      formatter = noFormat;
      guards.parseCompare = true;
      expected = bom + "---\nvalue: true\n---\n\n# Page\n";
      path = "page.md";
    }
    {
      name = "parse-frontmatter-crlf-good";
      files = markedMarkdown (crlf "---\nvalue: true\n---\n# Page\n");
      formatter = noFormat;
      guards.parseCompare = true;
      expected = crlf "---\nvalue: true\n---\n\n# Page\n";
      path = "page.md";
    }
    {
      name = "parse-frontmatter-eof-formatter-blank";
      files = markedMarkdown "---\nvalue: true\n---";
      formatter = noFormat // {markdown = "printf '\\n' > page.md";};
      guards.parseCompare = true;
      expected = "---\nvalue: true\n---";
      path = "page.md";
    }
    {
      name = "frontmatter-reattach-truncated-bad";
      files = consumerFiles;
      formatter = generated.defaultFormatter;
      attach = brokenAttach;
      guards.parseCompare = true;
      fails = bytesChanged;
    }
  ];
  makeTree = case:
    generated.mkTree {
      name = "generated-fixture-${case.name}";
      inherit (case) files formatter;
      guards = case.guards or {};
      check = case.check or {};
    };
  makeScript = case: let
    tree = makeTree case;
  in
    pkgs.writeText "generated-fixture-${case.name}.sh" ''
      #!/usr/bin/env bash
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      runHook() { :; }
      ${withAttach (case.attach or null) tree.buildPhase}
      ${case.postBuild or ""}
      ${tree.installPhase}
      ${tree.installCheckPhase}
    '';
  mutatedTree =
    (generated.mkTree {
      name = "generated-fixture-real-frontmatter-byte-failure";
      files = consumerFiles;
      formatter = generated.defaultFormatter;
      guards.parseCompare = true;
    }).overrideAttrs (_: {
      postBuild = "sed -i 's/  - \"SCHEMA.md\"/  - SCHEMA.md/' work/markdown/page.md";
    });
  expectedMutationFailure = pkgs.testers.testBuildFailure mutatedTree;
  treefmtConfig = (inputs.treefmt-nix.lib.evalModule pkgs (import ../../treefmt.nix)).config;
  treefmtTree = generated.mkTree {
    name = "generated-fixture-treefmt-eval-module";
    files = markdown "#   Heading\n";
    formatter.markdown = (import ../../lib/ai {inherit lib;}).treefmtFormatter treefmtConfig;
  };
in {
  checks.generated-files-treefmt-eval-module = pkgs.runCommandLocal "generated-files-treefmt-eval-module" {} ''
    test "$(cat ${treefmtTree}/page.md)" = "# Heading"
    touch "$out"
  '';
  checks.generated-files = pkgs.runCommandLocal "generated-files-check" {} ''
    export HOME="$TMPDIR"

    ${lib.concatMapStringsSep "\n" (case: let
        caseName = lib.escapeShellArg case.name;
        script = makeScript case;
      in ''
        mkdir -p "$TMPDIR"/${caseName}
        (
          cd "$TMPDIR"/${caseName}
          export out="$PWD/output"
          rc=0
          ${pkgs.bash}/bin/bash ${script} >probe.log 2>&1 || rc=$?
          ${
          if case ? fails
          then ''
            if [ "$rc" -eq 0 ]; then
              echo "FAIL: ${case.name} unexpectedly passed" >&2
              cat probe.log >&2
              exit 1
            fi
            grep -q -F ${lib.escapeShellArg case.fails} probe.log || {
              echo "FAIL: ${case.name} failed for the wrong reason" >&2
              cat probe.log >&2
              exit 1
            }
          ''
          else ''
            if [ "$rc" -ne 0 ]; then
              echo "FAIL: ${case.name} exited $rc" >&2
              cat probe.log >&2
              exit 1
            fi
          ''
        }
          ${lib.optionalString (case ? changed) ''
          ! cmp -s before/${case.files.${case.changed}.type}/${lib.escapeShellArg case.changed} "$out"/${lib.escapeShellArg case.changed} \
            || { echo "FAIL: ${case.name} did not format" >&2; exit 1; }
        ''}
          ${lib.optionalString (case ? head) ''
          printf '%s' ${lib.escapeShellArg case.head} | cmp -n ${toString (builtins.stringLength case.head)} - "$out"/page.md \
            || { echo "FAIL: ${case.name} changed generator frontmatter bytes" >&2; exit 1; }
        ''}
          ${lib.optionalString (case ? expected) ''
          printf '%s' ${lib.escapeShellArg case.expected} | cmp - "$out"/${lib.escapeShellArg case.path} \
            || { echo "FAIL: ${case.name} did not preserve its chosen formatter result" >&2; exit 1; }
        ''}
          ${lib.optionalString (case ? checked) ''
          printf '%s' ${lib.escapeShellArg case.checked} | cmp - check/${case.files.${case.path}.type}/${lib.escapeShellArg case.path} \
            || { echo "FAIL: ${case.name} did not run its user check on a copy" >&2; exit 1; }
        ''}
          ${lib.optionalString (case ? absent) ''
          test -f work/markdown/${lib.escapeShellArg case.absent} \
            || { echo "FAIL: ${case.name} did not exercise formatter state" >&2; exit 1; }
          test ! -e "$out"/${lib.escapeShellArg case.absent} \
            || { echo "FAIL: ${case.name} shipped formatter state" >&2; exit 1; }
        ''}
          echo "ok — ${case.name}"
        )
      '')
      cases}

    grep -q -F ${lib.escapeShellArg bytesChanged} ${expectedMutationFailure}/testBuildFailure.log
    grep -q -F 'Generated-file guard parseCompare failed' ${expectedMutationFailure}/testBuildFailure.log
    grep -q -F 'Choose one of three options:' ${expectedMutationFailure}/testBuildFailure.log
    echo 'ok — actual mkTree byte guard fails from installCheckPhase'
    touch "$out"
  '';
}
