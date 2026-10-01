# Public guard programs and the consumer check, exercised on authored Markdown.
{
  lib,
  pkgs,
  self,
  ...
}: let
  guards = self.lib.ai.guards pkgs;
  tables = ./fixtures/markdown-table-cells;
  # table-pipe.md: an excess body cell (markdownlint's half of tableCells).
  # table-break.md: header and delimiter disagree (rumdl's half).
  fixtures = {
    "clean.md" = ./fixtures/guards-consumer/clean.md.fixture;
    "inline-disable.md" = pkgs.writeText "inline-disable.md" ("<!-- markdownlint-disable MD056 -->\n\n" + builtins.readFile "${tables}/cause-excess-body-cell.md.fixture");
    "inline-widen.md" = ./fixtures/guards-consumer/inline-widen.md.fixture;
    "kiro-flow.md" = pkgs.writeText "kiro-flow.md" ''
      ---
      fileMatchPattern: ["one/**",
        "two/**"]
      ---
      # Kiro flow
    '';
    "split-span.md" = ./fixtures/guards-consumer/split-span.md.fixture;
    "table-break.md" = "${tables}/break-header-delimiter-disagree.md.fixture";
    "table-pipe.md" = "${tables}/cause-excess-body-cell.md.fixture";
  };
  tree = name: files:
    pkgs.runCommand "guards-consumer-${name}-tree" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${pkgs.coreutils}/bin/mkdir -p "$out"
      ${lib.concatStrings (lib.mapAttrsToList (path: source: ''
          ${pkgs.coreutils}/bin/mkdir -p "$out"/${lib.escapeShellArg (builtins.dirOf path)}
          ${pkgs.coreutils}/bin/cp ${source} "$out"/${lib.escapeShellArg path}
        '')
        files)}
    '';
  fixtureTree = tree "all" fixtures;
  failure = args: pkgs.testers.testBuildFailure (guards.check args);
  # Every defect present: splitCodeSpans runs first and fails.
  badDefault = failure {src = fixtureTree;};
  # splitCodeSpans disabled: the table defect is what fails.
  badTableOnly = failure {
    src = fixtureTree;
    guards.splitCodeSpans = false;
  };
  # tableCells disabled over a tree whose only defect is a table: passes.
  tableDisabled = guards.check {
    src = tree "table-only" {
      "clean.md" = fixtures."clean.md";
      "table-pipe.md" = fixtures."table-pipe.md";
    };
    guards.tableCells = false;
  };
  kiroTree = tree "kiro-only" {".kiro/steering/bad.md" = fixtures."kiro-flow.md";};
  badKiroDefault = failure {src = kiroTree;};
  kiroOutsideLayout = guards.check {
    src = tree "kiro-outside-layout" {"docs/bad.md" = fixtures."kiro-flow.md";};
  };
  badKiroCustom = failure {
    src = tree "kiro-custom" {"custom/steering/bad.md" = fixtures."kiro-flow.md";};
    kiroDir = "custom";
  };
  # A glob metacharacter in the directory name matches literally.
  badKiroMeta = failure {
    src = tree "kiro-meta" {"kiro[1]/steering/bad.md" = fixtures."kiro-flow.md";};
    kiroDir = "kiro[1]";
  };
  kiroMetaUnrelated = guards.check {
    src = tree "kiro-meta-unrelated" {"kiro1/steering/bad.md" = fixtures."kiro-flow.md";};
    kiroDir = "kiro[1]";
  };
  kiroDisabled = guards.check {
    src = kiroTree;
    guards.kiroFrontmatterFlow = false;
  };
  # A configuration file in the checked tree cannot silence either half.
  badConfigured = lib.mapAttrs (name: files: failure {src = tree name files;}) {
    markdownlint = {
      ".markdownlint-cli2.jsonc" = pkgs.writeText "cli2" ''{ "config": { "MD056": false }, "ignores": ["**/*.md"] }'';
      "table-pipe.md" = fixtures."table-pipe.md";
    };
    rumdl = {
      ".rumdl.toml" = pkgs.writeText "rumdl" ''
        [global]
        exclude = ["*.md", "**/*.md"]
      '';
      "table-break.md" = fixtures."table-break.md";
    };
  };
  json = text: pkgs.writeText "data.json" text;
  rejected = value: !(builtins.tryEval (builtins.seq value true)).success;
in {
  checks.guards-consumer = assert lib.assertMsg (guards ? kiroFrontmatterFlow)
  "guards-consumer: lib.ai.guards does not export kiroFrontmatterFlow";
  assert lib.assertMsg (rejected (guards.check {
    src = fixtureTree;
    guards.parseCompare = true;
  })) "guards-consumer: parseCompare was accepted by check";
    pkgs.runCommand "guards-consumer-check" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      cd ${fixtureTree}

      # expect NAME EXIT PROGRAM ARGS...: run PROGRAM, require EXIT.
      expect() {
        local name=$1 want=$2 rc=0
        shift 2
        "$@" >"$TMPDIR/$name.log" 2>&1 || rc=$?
        if [ "$rc" -ne "$want" ]; then
          echo "FAIL: $name exited $rc, expected $want" >&2
          ${pkgs.coreutils}/bin/cat "$TMPDIR/$name.log" >&2
          exit 1
        fi
      }
      expect split-bad 1 ${lib.getExe guards.splitCodeSpans} split-span.md
      expect split-good 0 ${lib.getExe guards.splitCodeSpans} clean.md
      expect table-bad 1 ${lib.getExe guards.tableCells} table-pipe.md
      expect table-good 0 ${lib.getExe guards.tableCells} clean.md
      # Inline suppression is honoured; inline rules other than MD056 add nothing.
      expect table-inline 0 ${lib.getExe guards.tableCells} inline-disable.md
      expect table-other-rules 0 ${lib.getExe guards.tableCells} inline-widen.md
      expect parse-same 0 ${lib.getExe guards.parseCompare} json ${json ''{"a":true}''} ${json ''{ "a": true }''}
      expect parse-changed 1 ${lib.getExe guards.parseCompare} json ${json ''{"a":true}''} ${json ''{"a":false}''}
      expect parse-unparseable 2 ${lib.getExe guards.parseCompare} json ${json ''{"a":''} ${json ''{}''}

      found() { ${pkgs.gnugrep}/bin/grep -q -F "$1" "$2"; }
      found "Guard splitCodeSpans failed." ${badDefault}/testBuildFailure.log
      found "Guard tableCells failed." ${badTableOnly}/testBuildFailure.log
      found ".kiro/steering/bad.md: Kiro frontmatter flow sequence spans multiple lines" ${badKiroDefault}/testBuildFailure.log
      found "custom/steering/bad.md: Kiro frontmatter flow sequence spans multiple lines" ${badKiroCustom}/testBuildFailure.log
      found "kiro[1]/steering/bad.md: Kiro frontmatter flow sequence spans multiple lines" ${badKiroMeta}/testBuildFailure.log
      if found "Guard splitCodeSpans failed." ${badTableOnly}/testBuildFailure.log; then
        echo "FAIL: splitCodeSpans ran when disabled" >&2
        exit 1
      fi
      test -e ${tableDisabled}
      test -e ${kiroOutsideLayout}
      test -e ${kiroDisabled}
      test -e ${kiroMetaUnrelated}
      ${lib.concatMapStrings (drv: ''
        found "Guard tableCells failed." ${drv}/testBuildFailure.log
      '') (lib.attrValues badConfigured)}
      ${pkgs.coreutils}/bin/touch "$out"
    '';
}
