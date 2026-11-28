# Behavioral fixtures for the generated store-tree builder. Failure cases run
# the builder's real phases in fresh shells: a check derivation cannot invoke
# nested nix builds in its sandbox.
{
  inputs,
  lib,
  pkgs,
  ...
}: let
  generated = import ../../lib/generated.nix {inherit lib;} pkgs;
  onlyGuards = names: lib.genAttrs names (_: true);
  frontmatter = import ../../lib/frontmatter.nix {inherit lib;};
  mkFile = type: text: {inherit type text;};
  markdown = text: {"page.md" = mkFile "markdown" text;};
  roundTripDescription = ''a "quoted" word: and \ slash'';
  roundTripRendered = frontmatter.render {
    data.description = roundTripDescription;
    body = "# Body\n";
  };
  dataFile = type: text: {"data.${type}" = mkFile type text;};
  rewriteFormatter = type: text:
    (inputs.treefmt-nix.lib.evalModule pkgs {
      settings.formatter.rewrite = {
        command = toString (pkgs.writeShellScript "rewrite-${type}" ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          for file in "$@"; do
            printf '%s' ${lib.escapeShellArg text} > "$file"
          done
        '');
        includes = ["*.${type}"];
      };
    }).config;
  goodTable = ''    | a | b |
    | --- | --- |
    | x | y |
  '';
  badHeader = ''    | a | b | c |
    | --- | --- |
    | x | y |
  '';
  # Run this mutation through the actual mkTree derivation to verify that
  # stdenv runs the install check.
  frontmatterMutation = {
    name = "frontmatter-value-change-bad";
    fails = "parsed Markdown frontmatter values differ from";
    files = markdown "---\nname: \"a\"\n---\n\n# Page\n";
    guards = onlyGuards ["parseCompare"];
    treefmt = rewriteFormatter "md" "---\nname: \"b\"\n---\n\n# Page\n";
  };
  # Each type exercises its own formatter routing and parser dispatch.
  structured = {
    json = {
      formatted = "{ \"value\": true }\n";
      input = ''{"value":true}'';
      mutated = ''{"value":false}'';
    };
    toml = {
      formatted = "value = true\n";
      input = "value=true\n";
      mutated = "value = false\n";
    };
    yaml = {
      formatted = "value: true\n";
      input = "value:   true\n";
      mutated = "value: false\n";
    };
  };
  structuredCases = lib.concatLists (lib.mapAttrsToList (type: row: let
      common = {
        files = dataFile type row.input;
        guards = onlyGuards ["parseCompare"];
      };
    in [
      (common
        // {
          name = "format-${type}-default";
          expected = row.formatted;
          path = "data.${type}";
          treefmt = treefmtConfig;
        })
      (common
        // {
          name = "parse-${type}-rejects-value-change";
          fails = "parsed ${type} values differ from";
          treefmt = rewriteFormatter type row.mutated;
        })
    ])
    structured);
  multilineFlow = ''
    ---
    fileMatchPattern: ["one/**",
      "two/**"]
    ---
    # Page
  '';
  parseMarkdown = name: input: formatter: expected: {
    inherit expected name;
    files = markdown input;
    guards = onlyGuards ["parseCompare"];
    path = "page.md";
    treefmt = formatter;
  };
  cases =
    [
      # Normalize to a known LF header. Ignoring the original CRLF header
      # would compare an absent header with a present one and fail.
      (parseMarkdown "frontmatter-crlf-header-compares-values"
        "---\r\nname: a\r\n---\r\n\r\n# Page\r\n"
        (rewriteFormatter "md" "---\nname: a\n---\n\n# Page\n")
        "---\nname: a\n---\n\n# Page\n")
      # A thematic break must not switch on YAML parsing.
      (parseMarkdown "frontmatter-thematic-break-is-not-a-header"
        "---\n\n#   Title\n\nbody\n"
        treefmtConfig "---\n\n# Title\n\nbody\n")
      # Checking raw header bytes would reject the equivalent quote rewrite.
      (parseMarkdown "frontmatter-whole-file-format"
        "---\nname: 'a'\n---\n\n#   Page\n"
        treefmtConfig "---\nname: \"a\"\n---\n\n# Page\n")

      {
        name = "split-code-spans-rejects-before-repair";
        fails = "ERROR: inline code spans split across a newline.";
        files = markdown "A `split\nspan` is broken.\n";
        guards = onlyGuards ["splitCodeSpans"];
        # Repair the defect so that a guard moved after formatting misses it.
        treefmt = rewriteFormatter "md" "A `split span` is sound.\n";
      }
      {
        name = "table-cells-rejects-header-before-repair";
        fails = "MD056";
        files = markdown badHeader;
        guards = onlyGuards ["tableCells"];
        # Repair the defect so that a guard moved after formatting misses it.
        treefmt = rewriteFormatter "md" goodTable;
      }

      {
        name = "kiro-frontmatter-flow-disabled";
        files = markdown multilineFlow;
        guards = {};
        runtime = "kiro";
      }
      {
        name = "kiro-frontmatter-flow-rejects-formatter-output";
        fails = "page.md: Kiro frontmatter flow sequence spans multiple lines";
        files = markdown "# Page\n";
        guards = onlyGuards ["kiroFrontmatterFlow"];
        runtime = "kiro";
        treefmt = rewriteFormatter "md" multilineFlow;
      }
      {
        name = "kiro-frontmatter-flow-rejects-raw-copy";
        fails = ".kiro/steering/raw.md: Kiro frontmatter flow sequence spans multiple lines";
        files.".kiro/steering/raw.md" = mkFile "raw" multilineFlow;
        guards = onlyGuards ["kiroFrontmatterFlow"];
        runtime = "kiro";
      }
      {
        name = "kiro-frontmatter-flow-skips-claude";
        files = markdown multilineFlow;
        guards = onlyGuards ["kiroFrontmatterFlow"];
        runtime = "claude";
      }
    ]
    ++ structuredCases;
  makeTree = case:
    generated.mkTree {
      name = "generated-fixture-${case.name}";
      inherit (case) files;
      guards = case.guards or {};
      runtime = case.runtime or "test";
      treefmt = case.treefmt or null;
    };
  makeScript = case: let
    tree = makeTree case;
  in
    pkgs.writeText "generated-fixture-${case.name}.sh" ''
      #!/usr/bin/env bash
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      runHook() { :; }
      ${tree.buildPhase}
      ${tree.installPhase}
      ${tree.installCheckPhase}
    '';
  expectedMutationFailure = pkgs.testers.testBuildFailure (makeTree frontmatterMutation);
  treefmtConfig = (inputs.treefmt-nix.lib.evalModule pkgs (import ../../treefmt.nix {inherit inputs;})).config;
in {
  checks = {
    # Raw interpolation into YAML would lose the quote, colon or backslash.
    frontmatter-scalar-round-trip =
      pkgs.runCommandLocal "frontmatter-scalar-round-trip" {
        nativeBuildInputs = [
          (pkgs.python3.withPackages (ps: [ps.pyyaml]))
        ];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :

        printf '%s' ${lib.escapeShellArg roundTripRendered} > rendered.md
        python3 - ${lib.escapeShellArg roundTripDescription} <<'PY'
        import pathlib
        import sys

        import yaml

        rendered = pathlib.Path("rendered.md").read_text()
        header = rendered.removeprefix("---\n").split("\n---\n", 1)[0]
        if yaml.safe_load(header)["description"] != sys.argv[1]:
            raise SystemExit("rendered description did not round-trip through YAML")
        PY
        touch "$out"
      '';
  };
  checks.generated-files = pkgs.runCommandLocal "generated-files-check" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    export HOME="$TMPDIR"

    ${lib.concatMapStringsSep "\n" (case: let
        caseName = lib.escapeShellArg case.name;
        script = makeScript case;
        status =
          if case ? fails
          then 1
          else 0;
      in ''
        mkdir -p "$TMPDIR"/${caseName}
        (
          cd "$TMPDIR"/${caseName}
          export out="$PWD/output"
          rc=0
          ${pkgs.bash}/bin/bash ${script} >probe.log 2>&1 || rc=$?
          if [ "$rc" -ne ${toString status} ]; then
            echo "FAIL: ${case.name} expected exit ${toString status}, got $rc" >&2
            cat probe.log >&2
            exit 1
          fi
          ${lib.optionalString (case ? fails) ''
          grep -q -F ${lib.escapeShellArg case.fails} probe.log || {
            echo "FAIL: ${case.name} failed for the wrong reason" >&2
            cat probe.log >&2
            exit 1
          }
        ''}
          ${lib.optionalString (case ? expected) ''
          printf '%s' ${lib.escapeShellArg case.expected} | cmp - "$out"/${lib.escapeShellArg case.path} \
            || { echo "FAIL: ${case.name} did not preserve its chosen formatter result" >&2; exit 1; }
        ''}
          echo "ok — ${case.name}"
        )
      '')
      cases}

    grep -q -F ${lib.escapeShellArg frontmatterMutation.fails} ${expectedMutationFailure}/testBuildFailure.log
    grep -q -F 'Generated-file guard parseCompare failed' ${expectedMutationFailure}/testBuildFailure.log
    echo 'ok — actual mkTree value guard fails from installCheckPhase'
    touch "$out"
  '';
}
