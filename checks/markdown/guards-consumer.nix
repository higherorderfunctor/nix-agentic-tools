# Public guard programs and the consumer check, exercised on authored Markdown.
{
  harness,
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
  # No explicit toggle: changing the Kiro guard default to off misses this.
  badKiroDefault = failure {src = kiroTree;};
  # Syntax alone must not select Markdown outside the Kiro layout.
  kiroOutsideLayout = guards.check {
    src = tree "kiro-outside-layout" {"docs/bad.md" = fixtures."kiro-flow.md";};
  };
  # Ignoring the override or globbing it would both miss the literal path.
  badKiroMeta = failure {
    src = tree "kiro-meta" {"kiro[1]/steering/bad.md" = fixtures."kiro-flow.md";};
    kiroDir = "kiro[1]";
  };
  # An unescaped bracket expression would select this unrelated directory.
  kiroMetaUnrelated = guards.check {
    src = tree "kiro-meta-unrelated" {"kiro1/steering/bad.md" = fixtures."kiro-flow.md";};
    kiroDir = "kiro[1]";
  };
  # The same default-path defect must pass when the Kiro guard is off.
  kiroDisabled = guards.check {
    src = kiroTree;
    guards.kiroFrontmatterFlow = false;
  };
  # Each external config tries to silence a different MD056 implementation.
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
in {
  checks.guards-consumer = assert harness.checkRows "guards-consumer" {
    "check rejects parseCompare (which needs two file versions)" = harness.rejectsChange (settings:
      lib.isDerivation (guards.check {
        src = fixtureTree;
        guards = settings;
      })) {
      valid = {};
      invalid.parseCompare = true;
      expected = true;
    };
    "removing the public Kiro executable breaks standalone callers" = guards ? kiroFrontmatterFlow;
  };
    pkgs.runCommand "guards-consumer-check" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      cd ${fixtureTree}

      found() { ${pkgs.gnugrep}/bin/grep -q -F "$1" "$2"; }

      # expect NAME EXIT FINDING PROGRAM ARGS...: empty FINDING for success.
      expect() {
        local name=$1 want=$2 finding=$3 rc=0 log="$TMPDIR/$1.log"
        shift 3
        "$@" >"$log" 2>&1 || rc=$?
        if [ "$rc" -ne "$want" ] || { [ -n "$finding" ] && ! found "$finding" "$log"; }; then
          echo "FAIL: $name expected exit $want and finding '$finding', got exit $rc:" >&2
          ${pkgs.coreutils}/bin/cat "$log" >&2
          exit 1
        fi
      }
      # A malformed BEFORE is not an ordinary mismatch: nothing was compared.
      expect parse-unparseable 2 "Nothing was compared: BEFORE must parse on its own." ${lib.getExe guards.parseCompare} json ${json ''{"a":''} ${json ''{}''}
      # This valid table is the success control for the generated-file and
      # linter fixture checks. Escaped pipes must not create extra cells.
      expect table-good 0 "" ${lib.getExe guards.tableCells} clean.md
      # Inline suppression is honoured; inline rules other than MD056 add nothing.
      expect table-inline 0 "" ${lib.getExe guards.tableCells} inline-disable.md
      expect table-other-rules 0 "" ${lib.getExe guards.tableCells} inline-widen.md

      found "Guard splitCodeSpans failed." ${badDefault}/testBuildFailure.log
      found "split-span.md:3:" ${badDefault}/testBuildFailure.log
      # Without the opt-out, the split finding aborts before the table guard.
      found "table-pipe.md:14 MD056" ${badTableOnly}/testBuildFailure.log
      found ".kiro/steering/bad.md: Kiro frontmatter flow sequence spans multiple lines" ${badKiroDefault}/testBuildFailure.log
      found "kiro[1]/steering/bad.md: Kiro frontmatter flow sequence spans multiple lines" ${badKiroMeta}/testBuildFailure.log
      test -e ${tableDisabled}
      test -e ${kiroOutsideLayout}
      test -e ${kiroDisabled}
      test -e ${kiroMetaUnrelated}
      ${lib.concatMapStrings (drv: ''
        found "Guard tableCells failed." ${drv}/testBuildFailure.log
        found "MD056" ${drv}/testBuildFailure.log
      '') (lib.attrValues badConfigured)}
      ${pkgs.coreutils}/bin/touch "$out"
    '';
}
