# Fixture suite for the `markdown-table-cells` gate — the regression half of
# its validation, and specifically the half that survives a tool update.
#
# WHAT IT GUARDS, and why the corpus cannot. The corpus scan says the repo is
# clean today. It cannot say WHICH linter earned that, and it goes on passing
# if one of the two silently stops working — a corpus with no broken tables in
# it reports the same green whether both tools are healthy or neither is.
#
# THE CLAIM UNDER TEST IS DISJOINTNESS, not detection. Two linters are carried
# because they share the rule NUMBER (MD056) and cover different halves of it:
#
#   header/delimiter disagree ("the break")  -> rumdl hits, markdownlint does not
#   excess body cell          ("the cause")  -> markdownlint hits, rumdl does not
#
# That asymmetry is the entire justification for the pair, and it is a MEASURED
# property of two third-party tools on this repo's update cadence — exactly the
# kind of claim that rots without anyone noticing. Both are absorbed overlays
# swept 4x/day, so either can change behavior on any sweep.
#
# So this suite fails LOUDLY in both directions:
#
#   - a tool stops catching its half  -> the gate has a hole; fix or replace it.
#   - a tool starts catching the OTHER half -> the pair may be redundant, and
#     the rationale in config/repo-validation.nix and the markdown-formatting
#     fragment is now WRONG and must be rewritten.
#
# The second direction is the one a plain "does it still find bugs?" test would
# miss, and it is the one that turns three files of prose into a lie.
#
# Two negative controls are included for the reason
# checks/doubled-words-fixtures.nix gives: without them, "both defect fixtures
# hit" is equally consistent with a linter that flags every table. `clean`
# proves a well-formed table passes; `escaped-pipe-in-code-span` proves the
# REMEDY this repo documents still works — if that one starts hitting, the fix
# in the fragment has stopped being a fix.
#
# The fixtures are `*.md.fixture`, NOT `*.md`, and that is load-bearing twice:
# `checks/markdown-scan.nix` walks every tracked `.md`, and the
# `markdown-table-cells` hook runs on every tracked `.md` — so a `.md` fixture
# carrying a deliberately broken table would fail the check it exists to test.
# treefmt would also rewrite the exact cell counts each one encodes.
{pkgs, ...}: let
  # The SAME packages the hook runs, not `pkgs.rumdl` / `pkgs.markdownlint-cli2`
  # from the nixpkgs pin. A fixture suite that validated different binaries from
  # the ones the gate uses would be measuring nothing.
  inherit (pkgs.ai.devTools) markdownlint-cli2 rumdl;

  markdownlintConfig = pkgs.writeText "markdownlint-tables.jsonc" ''
    { "default": false, "MD056": true }
  '';

  fixtures = ./fixtures/markdown-table-cells;
in
  pkgs.runCommandLocal "markdown-table-cells-fixtures-check" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :

    # markdownlint-cli2 writes state under HOME and refuses a read-only one.
    export HOME="$TMPDIR"
    cd "$TMPDIR"

    fail() {
      echo "FAIL: $1" >&2
      echo "" >&2
      echo "This suite pins the DISJOINTNESS of two linters that share rule MD056." >&2
      echo "One of them changed behavior. Before touching this file, decide which:" >&2
      echo "  * a tool stopped catching its half  -> the gate has a hole." >&2
      echo "  * a tool started catching the other -> the pair may be redundant, and" >&2
      echo "    the rationale in config/repo-validation.nix plus the" >&2
      echo "    markdown-formatting fragment is now WRONG and must be rewritten." >&2
      echo "" >&2
      echo "Do not 'fix' this by relaxing the assertion." >&2
      exit 1
    }

    # Returns 0 when the tool reports a finding, 1 when it is silent. Both
    # exit non-zero on a hit, so this inverts into a readable predicate.
    hits() {
      local tool="$1" file="$2"
      case "$tool" in
        rumdl)
          if ${rumdl}/bin/rumdl check --enable MD056 --no-config "$file" >/dev/null 2>&1
          then return 1; else return 0; fi ;;
        markdownlint)
          if ${markdownlint-cli2}/bin/markdownlint-cli2 --config ${markdownlintConfig} "$file" >/dev/null 2>&1
          then return 1; else return 0; fi ;;
        *) fail "unknown tool '$tool'" ;;
      esac
    }

    # markdownlint-cli2 resolves its arguments as globs and silently scans
    # NOTHING when a literal path does not match one — measured, and it reports
    # "0 issues in 0 files" while exiting 0, which reads exactly like a pass.
    # Copying each fixture to a plain `.md` under $TMPDIR sidesteps that and
    # also gives both tools the extension they expect. It is a copy, so the
    # tracked fixture keeps its `.md.fixture` name.
    check() {
      local name="$1" wantRumdl="$2" wantMdl="$3"
      # --no-preserve=mode: store files are read-only, and without this the
      # SECOND copy cannot overwrite the first and the suite dies half-run.
      ${pkgs.coreutils}/bin/cp --no-preserve=mode,ownership \
        "${fixtures}/$name.md.fixture" "$TMPDIR/case.md"

      if hits rumdl "$TMPDIR/case.md"; then gotRumdl=hit; else gotRumdl=silent; fi
      if hits markdownlint "$TMPDIR/case.md"; then gotMdl=hit; else gotMdl=silent; fi

      [ "$gotRumdl" = "$wantRumdl" ] \
        || fail "$name: rumdl expected $wantRumdl, got $gotRumdl"
      [ "$gotMdl" = "$wantMdl" ] \
        || fail "$name: markdownlint expected $wantMdl, got $gotMdl"

      echo "ok — $name: rumdl=$gotRumdl markdownlint=$gotMdl"
    }

    #      fixture                              rumdl    markdownlint
    check break-header-delimiter-disagree       hit      silent
    check cause-excess-body-cell                silent   hit
    check clean                                 silent   silent
    check escaped-pipe-in-code-span             silent   silent

    ${pkgs.coreutils}/bin/mkdir -p "$out"
    ${pkgs.coreutils}/bin/touch "$out/ok"
  ''
