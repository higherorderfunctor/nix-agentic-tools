# Behavioral fixtures for the generated store-tree builder. Failure cases run
# cspell:ignore FEFF reserialized ufeff
# the builder's real phases in fresh shells: a check derivation cannot invoke
# nested nix builds in its sandbox. The final case also builds a failing mkTree
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
  renderedMarkdown = {
    "page.md" =
      {type = "markdown";}
      // frontmatter.treeFile (frontmatter.render {
        data = {value = "true";};
        body = "# Page\n";
      });
  };
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
  # Test-only copies of the guard whose attach step restores the wrong header,
  # standing in for a defect in the split/reattach logic itself. The identity
  # copy is the control: same substitution, unchanged logic.
  guardScript = ../../lib/generated-guard.py;
  bytesChanged = "installed Markdown frontmatter bytes differ from the generator bytes";
  attachCommand = script: "${script} attach";
  patchedGuard = name: replacement: let
    source = builtins.readFile guardScript;
    anchor = "prefix = header_file.read_bytes()";
  in
    assert lib.assertMsg (lib.hasInfix anchor source) "generated-files: the attach anchor moved in lib/generated-guard.py";
      pkgs.writeText "generated-guard-${name}.py" (builtins.replaceStrings [anchor] [replacement] source);
  brokenAttach = {
    identity = patchedGuard "identity" "prefix = header_file.read_bytes()";
    # Drops the last YAML line before the closing fence.
    truncated = patchedGuard "truncated" ''prefix = re.sub(rb"[^\n]*\n(---\n)\Z", rb"\1", header_file.read_bytes())'';
    # Parsed-equal, presentation-different: what a YAML round trip produces.
    reserialized = patchedGuard "reserialized" ''prefix = b"---\n" + yaml.safe_dump(yaml.safe_load(frontmatter_parts(header_file.read_bytes(), True)[1]), sort_keys=False, width=4096).encode() + b"---\n"'';
  };
  withAttach = script: phase: let
    replaced = builtins.replaceStrings [(attachCommand guardScript)] [(attachCommand script)] phase;
  in
    if script == null
    then phase
    else assert lib.assertMsg (replaced != phase) "generated-files: mkTree no longer calls the guard attach step"; replaced;
  customNarrowFormatter = "find . -type f -print0 | xargs -0 -r ${lib.getExe' pkgs.prettier "prettier"} --write --parser markdown --print-width 30";
  python = pkgs.python3.withPackages (ps: [ps.pyyaml]);
  bom = builtins.fromJSON ''"\uFEFF"'';
  crlf = builtins.replaceStrings ["\n"] ["\r\n"];
  dataFile = type: text: {"data.${type}" = mkFile type text;};
  mutateFrontmatter = closing: "printf '%s\\n' '---' 'value: 1' '${closing}' '# Page' > page.md";
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
      files = dataFile "json" ''{"a":true}'';
      formatter = generated.defaultFormatter;
      guards.parseCompare = true;
      changed = "data.json";
    }
    {
      name = "format-json-extensionless";
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
      files = {
        "nested/data.toml" =
          mkFile "toml" ''            a=1
          '';
      };
      formatter = generated.defaultFormatter;
      guards.parseCompare = true;
      changed = "nested/data.toml";
    }
    {
      name = "format-toml-extensionless";
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
      name = "guard-precedes-user-repair";
      files = markdown badTable;
      formatter = noFormat;
      guards.tableCells = true;
      check.markdown = "printf '%s' ${lib.escapeShellArg goodTable} > page.md";
      fails = "tableCells";
    }
    {
      name = "user-check-cannot-change-output";
      files = markdown goodTable;
      formatter = noFormat;
      guards.tableCells = true;
      check.markdown = "printf '%s' ${lib.escapeShellArg badTable} > page.md";
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
      name = "parse-json-nonstandard-constant-bad";
      files = dataFile "json" ''{"value":NaN}'';
      formatter = noFormat;
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
      name = "parse-toml-good";
      files =
        dataFile "toml" ''          value = true
        '';
      formatter = noFormat;
      guards.parseCompare = true;
    }
    {
      name = "parse-toml-nan-good";
      files =
        dataFile "toml" ''          value = nan
        '';
      formatter = noFormat;
      guards.parseCompare = true;
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
      name = "parse-toml-disabled";
      files =
        dataFile "toml" ''          value = true
        '';
      formatter = noFormat // {toml = "printf 'value = 1\\n' > data.toml";};
      guards.parseCompare = false;
    }
    {
      name = "parse-yaml-good";
      files =
        dataFile "yaml" ''          value: true
        '';
      formatter = noFormat;
      guards.parseCompare = true;
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
      name = "parse-yaml-disabled";
      files =
        dataFile "yaml" ''          value: true
        '';
      formatter = noFormat // {yaml = "printf 'value: 1\\n' > data.yaml";};
      guards.parseCompare = false;
    }
    {
      name = "parse-frontmatter-good";
      files = markedMarkdown ''        ---
        value: true
        ---
        # Page
      '';
      formatter = noFormat;
      guards.parseCompare = true;
    }
    {
      name = "parse-frontmatter-rendered-good";
      files = renderedMarkdown;
      formatter = generated.defaultFormatter;
      guards.parseCompare = true;
    }
    {
      name = "frontmatter-consumer-default-bytes";
      files = consumerFiles;
      formatter = generated.defaultFormatter;
      guards.parseCompare = true;
      head = frontmatter.block consumerData + "\n";
    }
    {
      name = "frontmatter-consumer-custom-bytes";
      files = consumerFiles;
      formatter = noFormat // {markdown = customNarrowFormatter;};
      guards.parseCompare = true;
      head = frontmatter.block consumerData + "\n";
    }
    {
      name = "parse-unmarked-new-generator-bad";
      files = markdown "---\nvalue: true\n---\n# Page\n";
      formatter = generated.defaultFormatter;
      fails = "without its marker";
    }
    {
      name = "parse-unmarked-formatter-adds-mapping-bad";
      files = markdown "# Page\n";
      formatter = noFormat // {markdown = "printf '%s\\n' '---' 'value: true' '---' '# Page' > page.md";};
      fails = "without its marker";
    }
    {
      name = "parse-frontmatter-empty-good";
      files = markedMarkdown ''        ---
        ---
        # Page
      '';
      formatter = noFormat;
      guards.parseCompare = true;
    }
    {
      name = "parse-leading-thematic-break-good";
      files = markdown ''        ---

        # Heading
      '';
      formatter = generated.defaultFormatter;
      guards.parseCompare = true;
    }
    {
      name = "parse-thematic-pair-good";
      files = markdown ''        ---

        # Heading

        Ordinary prose: with: another colon.

        ---
      '';
      formatter = generated.defaultFormatter;
      guards.parseCompare = true;
    }
    {
      name = "parse-frontmatter-eof-good";
      files = markedMarkdown "---\nvalue: true\n---";
      formatter = generated.defaultFormatter;
      guards.parseCompare = true;
    }
    {
      name = "parse-frontmatter-bom-good";
      files = markedMarkdown (bom + "---\nvalue: true\n---\n# Page\n");
      formatter = noFormat;
      guards.parseCompare = true;
      expected = bom + "---\nvalue: true\n---\n\n# Page\n";
      path = "page.md";
    }
    {
      name = "parse-frontmatter-bom-mutated";
      files = markedMarkdown (bom + "---\nvalue: true\n---\n# Page\n");
      formatter = noFormat;
      postBuild = "sed -i 's/value: true/value: 1/' work/markdown/page.md";
      guards.parseCompare = true;
      fails = bytesChanged;
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
      name = "parse-frontmatter-crlf-mutated";
      files = markedMarkdown (crlf "---\nvalue: true\n---\n# Page\n");
      formatter = noFormat;
      postBuild = "sed -i 's/value: true/value: 1/' work/markdown/page.md";
      guards.parseCompare = true;
      fails = bytesChanged;
    }
    {
      name = "parse-frontmatter-bom-crlf-formatter";
      files = markedMarkdown (bom + crlf "---\nvalue: true\n---\n# Page\n");
      formatter = noFormat // {markdown = "printf '# Page\\n' > page.md";};
      guards.parseCompare = true;
      expected = bom + crlf "---\nvalue: true\n---\n\n" + "# Page\n";
      path = "page.md";
    }
    {
      name = "parse-frontmatter-add-leading-blank";
      files = markedMarkdown "---\nvalue: true\n---\n# Page\n";
      formatter = noFormat // {markdown = "printf '\\n# Page\\n' > page.md";};
      guards.parseCompare = true;
      expected = "---\nvalue: true\n---\n\n# Page\n";
      path = "page.md";
    }
    {
      name = "parse-frontmatter-remove-leading-blank";
      files = markedMarkdown "---\nvalue: true\n---\n\n\n# Page\n";
      formatter = noFormat // {markdown = "printf '# Page\\n' > page.md";};
      guards.parseCompare = true;
      expected = "---\nvalue: true\n---\n\n# Page\n";
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
      name = "parse-frontmatter-dotted-good";
      files = markedMarkdown ''        ---
        value: true
        ...
        # Page
      '';
      formatter = generated.defaultFormatter;
      guards.parseCompare = true;
    }
    {
      name = "parse-frontmatter-formatter-cannot-remove-opening";
      files = markedMarkdown "---\nvalue: true\n---\n# Page\n";
      formatter = noFormat // {markdown = "printf '%s\\n' 'value: true' '---' '# Page' > page.md";};
      guards.parseCompare = true;
      head = "---\nvalue: true\n---\n";
    }
    {
      name = "parse-frontmatter-formatter-cannot-remove-closing";
      files = markedMarkdown "---\nvalue: true\n---\n# Page\n";
      formatter = noFormat // {markdown = "printf '%s\\n' '---' 'value: true' '# Page' > page.md";};
      guards.parseCompare = true;
      head = "---\nvalue: true\n---\n";
    }
    {
      name = "parse-frontmatter-opening-removed-bad";
      files = markedMarkdown "---\nvalue: true\n---\n# Page\n";
      formatter = noFormat // {markdown = "printf '%s\\n' 'value: true' '---' '# Page' > page.md";};
      postBuild = "sed -i '1d' work/markdown/page.md";
      guards.parseCompare = true;
      fails = "missing its opening frontmatter fence";
    }
    {
      name = "parse-frontmatter-opening-removed-disabled";
      files = markedMarkdown "---\nvalue: true\n---\n# Page\n";
      formatter = noFormat // {markdown = "printf '%s\\n' 'value: true' '---' '# Page' > page.md";};
      postBuild = "sed -i '1d' work/markdown/page.md";
      guards.parseCompare = false;
      expected = "value: true\n---\n\nvalue: true\n---\n# Page\n";
      path = "page.md";
    }
    {
      name = "parse-frontmatter-bad";
      files = markedMarkdown ''        ---
        value: true
        ---
        # Page
      '';
      formatter = noFormat // {markdown = mutateFrontmatter "---";};
      postBuild = "sed -i 's/value: true/value: 1/' work/markdown/page.md";
      guards.parseCompare = true;
      fails = "parseCompare";
    }
    {
      name = "parse-frontmatter-dotted-bad";
      files = markedMarkdown ''        ---
        value: true
        ...
        # Page
      '';
      formatter = noFormat // {markdown = mutateFrontmatter "...";};
      postBuild = "sed -i 's/value: true/value: 1/' work/markdown/page.md";
      guards.parseCompare = true;
      fails = "parseCompare";
    }
    {
      name = "parse-frontmatter-disabled";
      files = markedMarkdown ''        ---
        value: true
        ---
        # Page
      '';
      formatter = noFormat // {markdown = mutateFrontmatter "---";};
      postBuild = "sed -i 's/value: true/value: 1/' work/markdown/page.md";
      guards.parseCompare = false;
      expected = "---\nvalue: 1\n---\n\n---\nvalue: 1\n---\n# Page\n";
      path = "page.md";
    }
    {
      name = "parse-frontmatter-dotted-disabled";
      files = markedMarkdown ''        ---
        value: true
        ...
        # Page
      '';
      formatter = noFormat // {markdown = mutateFrontmatter "...";};
      postBuild = "sed -i 's/value: true/value: 1/' work/markdown/page.md";
      guards.parseCompare = false;
      expected = "---\nvalue: 1\n...\n\n---\nvalue: 1\n...\n# Page\n";
      path = "page.md";
    }
    {
      name = "frontmatter-presentation-mutation-bad";
      files = consumerFiles;
      formatter = generated.defaultFormatter;
      postBuild = "sed -i 's/  - \"SCHEMA.md\"/  - SCHEMA.md/' work/markdown/page.md";
      guards.parseCompare = true;
      fails = bytesChanged;
    }
    {
      name = "frontmatter-closer-mutation-bad";
      files = consumerFiles;
      formatter = generated.defaultFormatter;
      postBuild = "sed -i '1!s/^---$/.../' work/markdown/page.md";
      guards.parseCompare = true;
      fails = bytesChanged;
    }
    {
      name = "frontmatter-reattach-control";
      files = consumerFiles;
      formatter = generated.defaultFormatter;
      attach = brokenAttach.identity;
      guards.parseCompare = true;
      head = frontmatter.block consumerData + "\n";
    }
    {
      name = "frontmatter-reattach-truncated-bad";
      files = consumerFiles;
      formatter = generated.defaultFormatter;
      attach = brokenAttach.truncated;
      guards.parseCompare = true;
      fails = bytesChanged;
    }
    {
      name = "frontmatter-reattach-reserialized-bad";
      files = consumerFiles;
      formatter = generated.defaultFormatter;
      attach = brokenAttach.reserialized;
      guards.parseCompare = true;
      fails = bytesChanged;
    }
    {
      name = "user-check-runs";
      files = dataFile "json" ''{"value":true}'';
      formatter = noFormat;
      check.json = "test -f data.json";
    }
    {
      name = "user-check-fails";
      files = dataFile "json" ''{"value":true}'';
      formatter = noFormat;
      check.json = "echo user-check-marker >&2; exit 19";
      fails = "user-check-marker";
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
  failingTree = generated.mkTree {
    name = "generated-fixture-real-check-failure";
    files = dataFile "json" ''{"value":true}'';
    formatter = noFormat;
    check.json = "echo real-check-failed >&2; exit 19";
  };
  expectedFailure = pkgs.testers.testBuildFailure failingTree;
  unmarkedTree = generated.mkTree {
    name = "generated-fixture-unmarked-generator";
    files = markdown "---\nvalue: true\n---\n# Page\n";
    formatter = noFormat;
  };
  expectedUnmarkedFailure = pkgs.testers.testBuildFailure unmarkedTree;
  encodedUnmarkedFailures = map (encoding:
    pkgs.testers.testBuildFailure (generated.mkTree {
      name = "generated-fixture-unmarked-${encoding.name}";
      files = markdown encoding.text;
      formatter = noFormat;
    })) [
    {
      name = "bom";
      text = bom + "---\nvalue: true\n---\n# Page\n";
    }
    {
      name = "crlf";
      text = crlf "---\nvalue: true\n---\n# Page\n";
    }
  ];
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
  brokenAttachFailures = map (variant:
    pkgs.testers.testBuildFailure ((generated.mkTree {
        name = "generated-fixture-real-reattach-${variant}";
        files = consumerFiles;
        formatter = generated.defaultFormatter;
        guards.parseCompare = true;
      }).overrideAttrs (old: {
        buildPhase = withAttach brokenAttach.${variant} old.buildPhase;
      }))) ["reserialized" "truncated"];
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

    grep -q -F 'real-check-failed' ${expectedFailure}/testBuildFailure.log
    grep -q -F 'without its marker' ${expectedUnmarkedFailure}/testBuildFailure.log
    ${lib.concatMapStringsSep "\n" (failure: "grep -q -F 'without its marker' ${failure}/testBuildFailure.log") encodedUnmarkedFailures}
    grep -q -F ${lib.escapeShellArg bytesChanged} ${expectedMutationFailure}/testBuildFailure.log
    grep -q -F 'Generated-file guard parseCompare failed' ${expectedMutationFailure}/testBuildFailure.log
    grep -q -F 'Choose one of three options:' ${expectedMutationFailure}/testBuildFailure.log
    ${lib.concatMapStringsSep "\n" (failure: "grep -q -F ${lib.escapeShellArg bytesChanged} ${failure}/testBuildFailure.log") brokenAttachFailures}
    ${python}/bin/python3 -c ${lib.escapeShellArg ''
      import pathlib
      import runpy
      import tempfile
      import yaml

      guard = runpy.run_path("${../../lib/generated-guard.py}")
      original = pathlib.Path("${pkgs.writeText "consumer-frontmatter.yaml" (frontmatter.block consumerData)}").read_text()
      mutated = original.replace('  - "SCHEMA.md"', '  - SCHEMA.md')
      assert original.startswith('---\n')
      assert '\r' not in original and not original.startswith('\ufeff')
      assert original != mutated
      assert yaml.safe_load(guard["frontmatter_parts"](original.encode(), True)[1]) == yaml.safe_load(guard["frontmatter_parts"](mutated.encode(), True)[1])
      assert len("${consumerData.description}") == 196
      assert "description: ${consumerData.description}\n" in original
      assert 'fileMatchPattern:\n  - "SCHEMA.md"\n' in original
      # The reserialized attach defect keeps parsed values, so only the byte
      # comparison against the generator catches it.
      broken = runpy.run_path("${brokenAttach.reserialized}")
      with tempfile.TemporaryDirectory() as scratch:
          header = pathlib.Path(scratch, "header")
          body = pathlib.Path(scratch, "body")
          header.write_bytes(original.encode())
          body.write_bytes(b"# Page\n")
          assert broken["partition"]("attach", str(body), str(header)) == 0
          attached = body.read_bytes()
      expected_prefix, expected_yaml, _ = guard["frontmatter_parts"](original.encode(), True)
      attached_prefix, attached_yaml, _ = guard["frontmatter_parts"](attached, True)
      assert attached_prefix != expected_prefix
      assert yaml.safe_load(attached_yaml) == yaml.safe_load(expected_yaml)
    ''}
    echo 'ok — actual mkTree build fails from installCheckPhase'
    touch "$out"
  '';
}
