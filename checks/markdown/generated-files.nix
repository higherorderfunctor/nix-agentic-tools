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
  cases = [
    {
      name = "frontmatter-whole-file-format";
      files = markdown "---\nname: 'a'\n---\n\n#   Page\n";
      treefmt = treefmtConfig;
      guards = onlyGuards ["parseCompare"];
      expected = "---\nname: \"a\"\n---\n\n# Page\n";
      path = "page.md";
    }
    {
      name = "frontmatter-value-change-bad";
      files = markdown "---\nname: \"a\"\n---\n\n# Page\n";
      treefmt = rewriteFormatter "md" "---\nname: \"b\"\n---\n\n# Page\n";
      guards = onlyGuards ["parseCompare"];
      fails = "parsed Markdown frontmatter values differ from";
    }
    {
      name = "frontmatter-thematic-break-is-not-a-header";
      files = markdown "---\n\n#   Title\n\nbody\n";
      treefmt = treefmtConfig;
      guards = onlyGuards ["parseCompare"];
      expected = "---\n\n# Title\n\nbody\n";
      path = "page.md";
    }
    {
      name = "frontmatter-crlf-header-compares-values";
      files = markdown "---\r\nname: a\r\n---\r\n\r\n# Page\r\n";
      treefmt = treefmtConfig;
      guards = onlyGuards ["parseCompare"];
    }
    {
      name = "format-json-default";
      files = dataFile "json" ''{"value":true}'';
      treefmt = treefmtConfig;
      guards = onlyGuards ["parseCompare"];
      expected = "{ \"value\": true }\n";
      path = "data.json";
    }
    {
      name = "format-toml-default";
      files = dataFile "toml" "value=true\n";
      treefmt = treefmtConfig;
      guards = onlyGuards ["parseCompare"];
      expected = "value = true\n";
      path = "data.toml";
    }
    {
      name = "format-yaml-default";
      files = dataFile "yaml" "value:   true\n";
      treefmt = treefmtConfig;
      guards = onlyGuards ["parseCompare"];
      expected = "value: true\n";
      path = "data.yaml";
    }

    {
      name = "table-cells-good";
      files = markdown goodTable;
      guards = onlyGuards ["tableCells"];
    }
    {
      name = "table-cells-header-before-format";
      files = markdown badHeader;
      treefmt = treefmtConfig;
      guards = onlyGuards ["tableCells"];
      fails = "tableCells";
    }
    {
      name = "surface-check-fails";
      files = {
        "skill.json" = mkFile "json" ''{"value":true}'' // {surface = "skills";};
      };
      checks.skills = "exit 7";
      runtime = "claude";
      fails = "Generated-file check failed for surface skills in runtime claude (exit 7)";
    }
    {
      name = "split-code-spans-good";
      files =
        markdown ''          A `single span` is sound.
        '';
      guards = onlyGuards ["splitCodeSpans"];
    }
    {
      name = "split-code-spans-bad";
      files = markdown ''        A `split
        span` is broken.
      '';
      treefmt = treefmtConfig;
      guards = onlyGuards ["splitCodeSpans"];
      fails = "splitCodeSpans";
    }
    {
      name = "parse-json-good";
      files = dataFile "json" ''{"value":true}'';
      guards = onlyGuards ["parseCompare"];
    }
    {
      name = "parse-json-bad";
      files = dataFile "json" ''{"value":true}'';
      treefmt = rewriteFormatter "json" ''{"value":false}'';
      guards = onlyGuards ["parseCompare"];
      fails = "parseCompare";
    }
    {
      name = "parse-toml-bad";
      files =
        dataFile "toml" ''          value = true
        '';
      treefmt = rewriteFormatter "toml" "value = false\n";
      guards = onlyGuards ["parseCompare"];
      fails = "parseCompare";
    }
    {
      name = "parse-yaml-bad";
      files =
        dataFile "yaml" ''          value: true
        '';
      treefmt = rewriteFormatter "yaml" "value: false\n";
      guards = onlyGuards ["parseCompare"];
      fails = "parseCompare";
    }

    {
      name = "kiro-frontmatter-flow-bad";
      files = markdown ''        ---
        inclusion: fileMatch
        fileMatchPattern: ["one/**",
          "two/**"]
        ---
        # Page
      '';
      guards = onlyGuards ["kiroFrontmatterFlow"];
      runtime = "kiro";
      fails = "page.md: Kiro frontmatter flow sequence spans multiple lines";
    }
    {
      name = "kiro-frontmatter-flow-raw-bad";
      files.".kiro/steering/raw.md" = mkFile "raw" ''
        ---
        fileMatchPattern: ["one/**",
          "two/**"]
        ---
        # Raw page
      '';
      guards = onlyGuards ["kiroFrontmatterFlow"];
      runtime = "kiro";
      fails = ".kiro/steering/raw.md: Kiro frontmatter flow sequence spans multiple lines";
    }
    {
      name = "kiro-frontmatter-flow-disabled";
      files = markdown ''        ---
        fileMatchPattern: ["one/**",
          "two/**"]
        ---
        # Page
      '';
      guards = {};
      runtime = "kiro";
    }
    {
      name = "kiro-frontmatter-flow-skips-claude";
      files = markdown ''        ---
        fileMatchPattern: ["one/**",
          "two/**"]
        ---
        # Page
      '';
      guards = onlyGuards ["kiroFrontmatterFlow"];
      runtime = "claude";
    }
  ];
  makeTree = case:
    generated.mkTree {
      name = "generated-fixture-${case.name}";
      inherit (case) files;
      checks = case.checks or {};
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
  expectedMutationFailure = pkgs.testers.testBuildFailure (makeTree (lib.findFirst (case: case.name == "frontmatter-value-change-bad") (throw "generated-files: the value-change fixture is gone") cases));
  treefmtConfig = (inputs.treefmt-nix.lib.evalModule pkgs (import ../../treefmt.nix)).config;
  treefmtTree = generated.mkTree {
    name = "generated-fixture-treefmt-eval-module";
    files = markdown "#   Heading\n";
    guards = {};
    runtime = "test";
    treefmt = treefmtConfig;
  };
in {
  checks = {
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

    generated-files-treefmt-eval-module = pkgs.runCommandLocal "generated-files-treefmt-eval-module" {} ''
      test "$(cat ${treefmtTree}/page.md)" = "# Heading"
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
          ${lib.optionalString (case ? expected) ''
          printf '%s' ${lib.escapeShellArg case.expected} | cmp - "$out"/${lib.escapeShellArg case.path} \
            || { echo "FAIL: ${case.name} did not preserve its chosen formatter result" >&2; exit 1; }
        ''}
          echo "ok — ${case.name}"
        )
      '')
      cases}

    grep -q -F 'parsed Markdown frontmatter values differ from' ${expectedMutationFailure}/testBuildFailure.log
    grep -q -F 'Generated-file guard parseCompare failed' ${expectedMutationFailure}/testBuildFailure.log
    echo 'ok — actual mkTree value guard fails from installCheckPhase'
    touch "$out"
  '';
}
