# Behavioral fixtures for the generated store-tree builder. Failure cases run
# the builder's real phases in fresh shells: a check derivation cannot invoke
# nested nix builds in its sandbox. The final case also builds a failing mkTree
# through nixpkgs' testBuildFailure to pin the stdenv install-check lifecycle.
{
  lib,
  pkgs,
  ...
}: let
  generated = import ../../lib/generated.nix {inherit lib;} pkgs;
  mkFile = type: text: {inherit type text;};
  markdown = text: {"page.md" = mkFile "markdown" text;};
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
  cases = [
    {
      name = "format-json";
      files = dataFile "json" ''{"a":true}'';
      formatter = generated.defaultFormatter;
      guards.parseCompare = true;
      changed = "data.json";
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
      files = markdown ''        ---
        value: true
        ---
        # Page
      '';
      formatter = noFormat;
      guards.parseCompare = true;
    }
    {
      name = "parse-frontmatter-empty-good";
      files = markdown ''        ---
        ---
        # Page
      '';
      formatter = noFormat;
      guards.parseCompare = true;
    }
    {
      name = "parse-frontmatter-bad";
      files = markdown ''        ---
        value: true
        ---
        # Page
      '';
      formatter = noFormat // {markdown = "printf '%s\\n' '---' 'value: 1' '---' '# Page' > page.md";};
      guards.parseCompare = true;
      fails = "parseCompare";
    }
    {
      name = "parse-frontmatter-disabled";
      files = markdown ''        ---
        value: true
        ---
        # Page
      '';
      formatter = noFormat // {markdown = "printf '%s\\n' '---' 'value: 1' '---' '# Page' > page.md";};
      guards.parseCompare = false;
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
      ${tree.buildPhase}
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
in {
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
    echo 'ok — actual mkTree build fails from installCheckPhase'
    touch "$out"
  '';
}
